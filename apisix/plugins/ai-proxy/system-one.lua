--
-- Licensed to the Apache Software Foundation (ASF) under one or more
-- contributor license agreements.  See the NOTICE file distributed with
-- this work for additional information regarding copyright ownership.
-- The ASF licenses this file to You under the Apache License, Version 2.0
-- (the "License"); you may not use this file except in compliance with
-- the License.  You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.
--

-- Client of the System One API (POST /v1/systemone) for the system_one
-- balancer of ai-proxy-multi. A System One model, such as TypeSafe's Jev, is a
-- discriminative model: given a `state` and typed questions, it returns a
-- probability distribution over the options of each question instead of
-- generated text. The balancer asks one `choice` question whose options are the
-- instance names, each with the instance's `description` as its criterion, and
-- ranks the instances by the returned probabilities.
--
-- Like the embedding client, the request goes through the shared ai-provider
-- layer, so endpoint parsing, auth and HTTP transport match the chat path, and
-- none of the client's headers are forwarded.
local core = require("apisix.core")
local ipairs = ipairs
local type = type
local tostring = tostring
local require = require
local byte = string.byte
local sub = string.sub

local _M = {}

-- Path of the API, used when `endpoint` has none.
local API_PATH = "/v1/systemone"
-- Id of the single question asked.
local QUESTION = "instance"
-- The prompt is sent as the `state`. A request body may be up to
-- max_req_body_size (64MB by default), but the API's default context is 32k
-- tokens for the state plus the question; longer inputs are refused or need a
-- slower long-context mode. 16 KiB keeps the state within it even at one byte
-- per token, and the routing signal is at the start of the prompt anyway.
local MAX_STATE_BYTES = 16384

local DEFAULT_INSTRUCTIONS = "Choose the option best suited to answer this "
    .. "request. Prefer the option whose criteria match the main task; options "
    .. "are not ordered by quality."


-- Cut `s` to at most `max` bytes without splitting a UTF-8 sequence: the API
-- accepts only valid UTF-8, and a prompt cut mid-character would be refused.
local function truncate(s, max)
    if #s <= max then
        return s
    end
    -- drop the continuation bytes (10xxxxxx) of the sequence the cut splits;
    -- a sequence has at most three
    local cut = max
    for _ = 1, 3 do
        local b = byte(s, cut + 1)
        if b < 0x80 or b >= 0xC0 then
            break
        end
        cut = cut - 1
    end
    return sub(s, 1, cut)
end


local function build_request(opts, state, instances)
    local criteria = core.table.new(0, #instances)
    for _, inst in ipairs(instances) do
        criteria[inst.name] = inst.description
    end
    return {
        model = opts.model,
        state = state,
        questions = {
            [QUESTION] = {
                type = "choice",
                instructions = opts.instructions or DEFAULT_INSTRUCTIONS,
                criteria = criteria,
            },
        },
    }
end


-- Rank the instances by the probability distribution of the answer: an array of
-- { name = instance name, probability = number }, most probable first, ties in
-- configured order. Options that are not instances are ignored; an instance the
-- model omits gets 0. The answer's `choice` and `confidence` are derived from
-- the distribution, so they are not read.
local function rank(answer, instances)
    local probs = type(answer) == "table" and answer.probabilities
    if type(probs) ~= "table" then
        return nil, "no probabilities for question '" .. QUESTION .. "'"
    end

    local ranking = core.table.new(#instances, 0)
    for i, inst in ipairs(instances) do
        local p = probs[inst.name]
        if p == nil then
            p = 0
        end
        -- NaN fails both comparisons, and cjson decodes `1e999` to infinity
        if type(p) ~= "number" or not (p >= 0 and p <= 1) then
            return nil, "invalid probability for instance '" .. inst.name .. "'"
        end
        ranking[i] = { name = inst.name, probability = p, order = i }
    end

    core.table.sort(ranking, function(a, b)
        if a.probability ~= b.probability then
            return a.probability > b.probability
        end
        return a.order < b.order
    end)

    if ranking[1].probability == 0 then
        return nil, "no instance has a positive probability"
    end
    return ranking
end


-- Ask the System One model to rank `instances` for `state`.
-- Returns the ranking (see rank()) or nil + err.
function _M.fetch(opts, state, instances)
    -- The generic OpenAI-compatible provider is used for its transport and auth
    -- handling only: the endpoint's own path wins over API_PATH, as it does for
    -- every provider.
    local ai_provider = require("apisix.plugins.ai-providers.openai-compatible")
    local extra_opts = {
        endpoint = opts.endpoint,
        target_path = API_PATH,
        auth = opts.auth,
    }
    local req_conf = {
        ssl_verify = opts.ssl_verify ~= false,
        timeout = opts.timeout or 3000,
        keepalive = true,
    }
    local body = build_request(opts, truncate(state, MAX_STATE_BYTES), instances)
    local status, raw_body, err = ai_provider:request(req_conf, body, extra_opts)

    -- The upstream body never reaches a log line or a returned error: it is
    -- third-party content that may echo the prompt back or forge log lines.
    if status ~= 200 then
        if err then
            return nil, "system one request failed: " .. err
        end
        return nil, "system one endpoint returned status " .. tostring(status)
    end

    -- `derr` is cjson's own parse error, which carries no body content.
    local data, derr = core.json.decode(raw_body)
    if type(data) ~= "table" or type(data.answers) ~= "table" then
        return nil, "invalid system one response: " .. (derr or "unexpected shape")
    end
    return rank(data.answers[QUESTION], instances)
end


return _M
