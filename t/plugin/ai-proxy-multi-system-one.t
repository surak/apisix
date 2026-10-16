#
# Licensed to the Apache Software Foundation (ASF) under one or more
# contributor license agreements.  See the NOTICE file distributed with
# this work for additional information regarding copyright ownership.
# The ASF licenses this file to You under the Apache License, Version 2.0
# (the "License"); you may not use this file except in compliance with
# the License.  You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
use t::APISIX 'no_plan';

log_level("info");
repeat_each(1);
no_long_string();
no_root_location();
no_shuffle();

add_block_preprocessor(sub {
    my ($block) = @_;

    if (!defined $block->request) {
        $block->set_value("request", "GET /t");
    }

    my $http_config = $block->http_config // <<_EOC_;
        # Mock System One API: answers the single choice question with a
        # probability distribution steered by keywords in the state.
        server {
            server_name mock_system_one;
            listen 6796;
            default_type 'application/json';
            # keep long states in memory, where get_body_data() reads them
            client_body_buffer_size 1m;
            location /v1/systemone {
                content_by_lua_block {
                    local json = require("cjson.safe")
                    ngx.req.read_body()
                    -- the System One call must not carry the client's headers
                    ngx.log(ngx.WARN, "s1-recv-cookie:", ngx.var.http_cookie or "none")
                    ngx.log(ngx.WARN, "s1-recv-auth:", ngx.var.http_authorization or "none")
                    local body = json.decode(ngx.req.get_body_data()) or {}
                    local q = body.questions and body.questions.instance or {}
                    local names = {}
                    for name, criterion in pairs(q.criteria or {}) do
                        names[#names + 1] = name .. "=" .. criterion
                    end
                    table.sort(names)
                    ngx.log(ngx.WARN, "s1-recv model=", body.model, " type=", q.type,
                            " criteria=", table.concat(names, "|"))
                    local raw_state = body.state or ""
                    ngx.log(ngx.WARN, "s1-recv-state-bytes:", #raw_state, " utf8:",
                            ngx.re.find(raw_state, "^", "u") and "valid" or "invalid")
                    local state = string.lower(raw_state)
                    ngx.log(ngx.WARN, "s1-recv-state:", state)

                    if state:find("servererror") then
                        -- an error body echoing the prompt, as some providers
                        -- do -- it must never reach our logs
                        ngx.status = 500
                        ngx.say('{"error":"bad input: ', state, ' SENSITIVE-ECHO"}')
                        return
                    elseif state:find("scalarbody") then
                        ngx.say("null")
                        return
                    elseif state:find("nanprob") then
                        ngx.say('{"answers":{"instance":{"probabilities":'
                                .. '{"code":1e999,"cheap":0,"default":0}}}}')
                        return
                    elseif state:find("noprobs") then
                        ngx.say('{"answers":{"instance":{"choice":"cheap",'
                                .. '"confidence":0.8}}}')
                        return
                    elseif state:find("slowanswer") then
                        ngx.sleep(0.5)
                    end

                    local probs
                    if state:find("unsure") then
                        probs = { code = 0.4, cheap = 0.35, default = 0.25 }
                    elseif state:find("python") or state:find("debug") then
                        probs = { code = 0.9, cheap = 0.05, default = 0.05 }
                    elseif state:find("translate") then
                        probs = { code = 0.1, cheap = 0.8, default = 0.1 }
                    else
                        probs = { code = 0.1, cheap = 0.2, default = 0.7 }
                    end
                    local choice, best = nil, -1
                    for name, p in pairs(probs) do
                        if p > best then
                            choice, best = name, p
                        end
                    end
                    ngx.say(json.encode({
                        model = body.model,
                        answers = { instance = {
                            choice = choice, confidence = best, probabilities = probs,
                        } },
                        usage = { input_tokens = 42, output_tokens = 1 },
                    }))
                }
            }
        }

        # Mock LLM: echoes the model it received so tests can tell which
        # instance was selected. /fail always answers 500.
        server {
            server_name mock_llm;
            listen 6795;
            default_type 'application/json';
            client_body_buffer_size 1m;
            location /v1/chat/completions {
                content_by_lua_block {
                    local json = require("cjson.safe")
                    ngx.req.read_body()
                    local body = json.decode(ngx.req.get_body_data()) or {}
                    ngx.print(body.model or "unknown")
                }
            }
            location /fail/v1/chat/completions {
                content_by_lua_block {
                    ngx.status = 500
                    ngx.print('{"error":"upstream down"}')
                }
            }
            location /status {
                return 200;
            }
        }
_EOC_
    $block->set_value("http_config", $http_config);

    my $user_yaml_config = <<_EOC_;
plugins:
  - ai-proxy-multi
  - ai-rate-limiting
_EOC_
    $block->set_value("extra_yaml_config", $user_yaml_config);
});

run_tests();

__DATA__

=== TEST 1: schema - system_one_opts, descriptions and fallback are validated
--- config
    location /t {
        content_by_lua_block {
            local plugin = require("apisix.plugins.ai-proxy-multi")
            local function inst(name, description)
                return {
                    name = name, provider = "openai", weight = 1,
                    auth = { header = { Authorization = "Bearer token" } },
                    description = description,
                }
            end
            local opts = { endpoint = "http://127.0.0.1:6796/v1/systemone",
                           model = "jev-latest" }
            local function check(conf)
                local ok, err = plugin.check_schema(conf)
                ngx.say(ok and "passed" or err)
            end

            check({ balancer = { algorithm = "system_one" }, system_one_opts = opts,
                    instances = { inst("a", "A."), inst("b", "B.") } })
            check({ balancer = { algorithm = "system_one" },
                    instances = { inst("a", "A."), inst("b", "B.") } })
            check({ balancer = { algorithm = "system_one" }, system_one_opts = opts,
                    instances = { inst("a", "A."), inst("b") } })
            check({ balancer = { algorithm = "system_one" },
                    system_one_opts = { endpoint = opts.endpoint, model = opts.model,
                                        fallback = "c" },
                    instances = { inst("a", "A."), inst("b", "B.") } })
            check({ balancer = { algorithm = "system_one" },
                    system_one_opts = { endpoint = "http:///v1/systemone",
                                        model = opts.model },
                    instances = { inst("a", "A."), inst("b", "B.") } })
            check({ balancer = { algorithm = "system_one" },
                    system_one_opts = { endpoint = opts.endpoint },
                    instances = { inst("a", "A."), inst("b", "B.") } })
            check({ balancer = { algorithm = "system_one" },
                    system_one_opts = { endpoint = opts.endpoint, model = opts.model,
                                        threshold = 1.5 },
                    instances = { inst("a", "A."), inst("b", "B.") } })
            -- descriptions are not required by the other algorithms
            check({ instances = { inst("a"), inst("b") } })
        }
    }
--- response_body
passed
must configure `system_one_opts` when balancer algorithm is system_one
instance 'b': must configure `description` for the system_one algorithm
`system_one_opts.fallback` names unknown instance 'c'
invalid `system_one_opts.endpoint`
property "system_one_opts" validation failed: property "model" is required
property "system_one_opts" validation failed: property "threshold" validation failed: expected 1.5 to be at most 1
passed



=== TEST 2: configure a system_one route (code / cheap / default)
--- config
    location /t {
        content_by_lua_block {
            -- Build the config as a Lua table: a long inline JSON block can
            -- cross nginx's config buffer boundary and be misparsed.
            local core = require("apisix.core")
            local t = require("lib.test_admin").test
            local function inst(name, model, description)
                return {
                    name = name, provider = "openai", weight = 1,
                    auth = { header = { Authorization = "Bearer llm-token" } },
                    options = { model = model },
                    override = { endpoint = "http://127.0.0.1:6795/v1/chat/completions" },
                    description = description,
                }
            end
            local conf = {
                uri = "/anything",
                plugins = {
                    ["ai-proxy-multi"] = {
                        balancer = { algorithm = "system_one" },
                        system_one_opts = {
                            endpoint = "http://127.0.0.1:6796/v1/systemone",
                            model = "jev-latest",
                            auth = { header = { Authorization = "Bearer s1-token" } },
                            threshold = 0.5,
                            fallback = "default",
                            timeout = 200,
                        },
                        instances = {
                            inst("code", "model-code", "Programming and debugging."),
                            inst("cheap", "model-cheap", "Translation and summaries."),
                            inst("default", "model-fallback", "Everything else."),
                        },
                        ssl_verify = false,
                    },
                },
            }
            local code, body = t('/apisix/admin/routes/1', ngx.HTTP_PUT,
                                 core.json.encode(conf))
            if code >= 300 then
                ngx.status = code
                ngx.say(body)
                return
            end
            ngx.say("passed")
        }
    }
--- response_body
passed
--- no_error_log
[error]



=== TEST 3: a coding prompt routes to the code instance
--- request
POST /anything
{"model":"auto","messages":[{"role":"system","content":"be brief"},{"role":"user","content":"help me debug this python code"}]}
--- more_headers
Content-Type: application/json
--- response_body chomp
model-code
--- error_log
s1-recv-auth:Bearer s1-token
s1-recv model=jev-latest type=choice criteria=cheap=Translation and summaries.|code=Programming and debugging.|default=Everything else.
s1-recv-state:help me debug this python code
system_one routing picked instance: code
--- no_error_log
[error]



=== TEST 4: a translation prompt routes to the cheap instance
--- request
POST /anything
{"model":"auto","messages":[{"role":"user","content":"please translate this to english"}]}
--- more_headers
Content-Type: application/json
--- response_body chomp
model-cheap
--- no_error_log
[error]



=== TEST 5: no instance clears the threshold, falls back to the fallback instance
--- request
POST /anything
{"model":"auto","messages":[{"role":"user","content":"unsure what this is"}]}
--- more_headers
Content-Type: application/json
--- response_body chomp
model-fallback
--- error_log
no available instance cleared the threshold, falling back to default
--- no_error_log
[error]



=== TEST 6: non-200 fails open to the fallback, without logging the upstream body
--- request
POST /anything
{"model":"auto","messages":[{"role":"user","content":"servererror python code"}]}
--- more_headers
Content-Type: application/json
--- error_code: 200
--- response_body chomp
model-fallback
--- error_log
system_one routing: system one endpoint returned status 500, falling back
--- no_error_log
SENSITIVE-ECHO
[error]



=== TEST 7: 200 with a non-table body fails open instead of raising
--- request
POST /anything
{"model":"auto","messages":[{"role":"user","content":"scalarbody python"}]}
--- more_headers
Content-Type: application/json
--- response_body chomp
model-fallback
--- error_log
invalid system one response
--- no_error_log
[error]



=== TEST 8: a non-finite probability fails open instead of poisoning the ranking
--- request
POST /anything
{"model":"auto","messages":[{"role":"user","content":"nanprob python"}]}
--- more_headers
Content-Type: application/json
--- response_body chomp
model-fallback
--- error_log
invalid probability for instance 'code'
--- no_error_log
[error]



=== TEST 9: an answer without probabilities fails open
--- request
POST /anything
{"model":"auto","messages":[{"role":"user","content":"noprobs python"}]}
--- more_headers
Content-Type: application/json
--- response_body chomp
model-fallback
--- error_log
system_one routing: no probabilities for question 'instance', falling back
--- no_error_log
[error]



=== TEST 10: a timeout fails open to the fallback
--- request
POST /anything
{"model":"auto","messages":[{"role":"user","content":"slowanswer python"}]}
--- more_headers
Content-Type: application/json
--- response_body chomp
model-fallback
--- error_log eval
qr/system_one routing: system one request failed: .*timeout, falling back/



=== TEST 11: client headers are not forwarded to the System One endpoint
--- request
POST /anything
{"model":"auto","messages":[{"role":"user","content":"help me debug this python code"}]}
--- more_headers
Content-Type: application/json
Cookie: session=super-secret
--- response_body chomp
model-code
--- error_log
s1-recv-cookie:none
--- no_error_log
s1-recv-cookie:session=super-secret



=== TEST 12: multimodal content arrays are routed by their text parts
--- request
POST /anything
{"model":"auto","messages":[{"role":"user","content":[{"type":"text","text":"debug my python"},{"type":"image_url","image_url":{"url":"data:image/png;base64,AAAA"}}]}]}
--- more_headers
Content-Type: application/json
--- response_body chomp
model-code
--- error_log
s1-recv-state:debug my python



=== TEST 13: a long prompt is cut to 16 KiB without splitting a UTF-8 character
--- request eval
"POST /anything\n"
. '{"model":"auto","messages":[{"role":"user","content":"x'
. ("\xc3\xbc" x 9000) . '"}]}'
--- more_headers
Content-Type: application/json
--- response_body chomp
model-fallback
--- error_log
s1-recv-state-bytes:16383 utf8:valid
--- no_error_log
[error]



=== TEST 14: reconfigure with debugging and ranked retry on 5xx
--- config
    location /t {
        content_by_lua_block {
            local core = require("apisix.core")
            local t = require("lib.test_admin").test
            local function inst(name, model, description, endpoint)
                return {
                    name = name, provider = "openai", weight = 1,
                    auth = { header = { Authorization = "Bearer llm-token" } },
                    options = { model = model },
                    override = { endpoint = endpoint
                                 or "http://127.0.0.1:6795/v1/chat/completions" },
                    description = description,
                }
            end
            local conf = {
                uri = "/anything",
                plugins = {
                    ["ai-proxy-multi"] = {
                        balancer = { algorithm = "system_one" },
                        system_one_opts = {
                            endpoint = "http://127.0.0.1:6796/v1/systemone",
                            model = "jev-latest",
                            fallback = "default",
                            debugging = true,
                        },
                        fallback_strategy = { "http_5xx" },
                        instances = {
                            inst("code", "model-code", "Programming and debugging.",
                                 "http://127.0.0.1:6795/fail/v1/chat/completions"),
                            inst("cheap", "model-cheap", "Translation and summaries."),
                            inst("default", "model-fallback", "Everything else."),
                        },
                        ssl_verify = false,
                    },
                },
            }
            local code, body = t('/apisix/admin/routes/1', ngx.HTTP_PUT,
                                 core.json.encode(conf))
            if code >= 300 then
                ngx.status = code
                ngx.say(body)
                return
            end
            ngx.say("passed")
        }
    }
--- response_body
passed



=== TEST 15: debugging headers expose the ranking and the pick
--- request
POST /anything
{"model":"auto","messages":[{"role":"user","content":"please translate this"}]}
--- more_headers
Content-Type: application/json
--- response_headers
X-AI-System-One-Probabilities: cheap:0.8000,code:0.1000,default:0.1000
X-AI-System-One-Picked-Instance: cheap
--- response_body chomp
model-cheap



=== TEST 16: a failing pick is retried on the next instance of the ranking
--- request
POST /anything
{"model":"auto","messages":[{"role":"user","content":"debug my python"}]}
--- more_headers
Content-Type: application/json
--- response_headers
X-AI-System-One-Picked-Instance: cheap
--- response_body chomp
model-cheap
--- error_log
ai instance code returned status 500, falling back to cheap
--- grep_error_log eval
qr/s1-recv-state:/
--- grep_error_log_out
s1-recv-state:



=== TEST 17: configure a route for the Responses and Anthropic Messages APIs
--- config
    location /t {
        content_by_lua_block {
            local core = require("apisix.core")
            local t = require("lib.test_admin").test
            local function inst(name, model, description)
                return {
                    name = name, provider = "openai", weight = 1,
                    auth = { header = { Authorization = "Bearer llm-token" } },
                    options = { model = model },
                    override = { endpoint = "http://127.0.0.1:6795/v1/chat/completions" },
                    description = description,
                }
            end
            local conf = {
                uris = { "/llm/v1/responses", "/llm/v1/messages" },
                plugins = {
                    ["ai-proxy-multi"] = {
                        balancer = { algorithm = "system_one" },
                        system_one_opts = {
                            -- no path: the API's /v1/systemone is used
                            endpoint = "http://127.0.0.1:6796",
                            model = "jev-latest",
                            threshold = 0.5,
                            fallback = "default",
                            debugging = true,
                        },
                        instances = {
                            inst("code", "model-code", "Programming and debugging."),
                            inst("cheap", "model-cheap", "Translation and summaries."),
                            inst("default", "model-fallback", "Everything else."),
                        },
                        ssl_verify = false,
                    },
                },
            }
            local code, body = t('/apisix/admin/routes/4', ngx.HTTP_PUT,
                                 core.json.encode(conf))
            if code >= 300 then
                ngx.status = code
                ngx.say(body)
                return
            end
            ngx.say("passed")
        }
    }
--- response_body
passed
--- no_error_log
[error]



=== TEST 18: a Responses request (body.input) is routed by its prompt
--- request
POST /llm/v1/responses
{"model":"auto","input":"help me debug this python code"}
--- more_headers
Content-Type: application/json
--- response_headers
X-AI-System-One-Probabilities: code:0.9000,cheap:0.0500,default:0.0500
X-AI-System-One-Picked-Instance: code
--- error_log
s1-recv-state:help me debug this python code
--- no_error_log
[error]



=== TEST 19: an Anthropic request (body.system + messages) is routed by the last user turn
--- request
POST /llm/v1/messages
{"model":"auto","max_tokens":64,"system":"translate everything","messages":[{"role":"user","content":"help me debug this python code"}]}
--- more_headers
Content-Type: application/json
--- response_headers
X-AI-System-One-Picked-Instance: code
--- error_log
s1-recv-state:help me debug this python code
--- no_error_log
[error]



=== TEST 20: an instance that fails its active health check is skipped
--- config
    location /t {
        content_by_lua_block {
            local core = require("apisix.core")
            local t = require("lib.test_admin").test
            local function inst(name, model, description, port)
                return {
                    name = name, provider = "openai", weight = 1,
                    auth = { header = { Authorization = "Bearer llm-token" } },
                    options = { model = model },
                    override = { endpoint = "http://127.0.0.1:" .. port
                                            .. "/v1/chat/completions" },
                    description = description,
                    checks = { active = {
                        type = "http",
                        http_path = "/status",
                        healthy = { interval = 1, successes = 1 },
                        unhealthy = { interval = 1, http_failures = 1,
                                      tcp_failures = 1, timeouts = 1 },
                    } },
                }
            end
            local conf = {
                uri = "/health",
                plugins = {
                    ["ai-proxy-multi"] = {
                        balancer = { algorithm = "system_one" },
                        system_one_opts = {
                            endpoint = "http://127.0.0.1:6796/v1/systemone",
                            model = "jev-latest",
                            fallback = "default",
                        },
                        instances = {
                            -- nothing listens on 6794: the checker marks it down
                            inst("code", "model-code", "Programming and debugging.", 6794),
                            inst("cheap", "model-cheap", "Translation and summaries.", 6795),
                            inst("default", "model-fallback", "Everything else.", 6795),
                        },
                        ssl_verify = false,
                    },
                },
            }
            local code, body = t('/apisix/admin/routes/2', ngx.HTTP_PUT,
                                 core.json.encode(conf))
            if code >= 300 then
                ngx.status = code
                ngx.say(body)
                return
            end

            local http = require("resty.http")
            local uri = "http://127.0.0.1:" .. ngx.var.server_port .. "/health"
            local function send()
                local httpc = http.new()
                local res = assert(httpc:request_uri(uri, {
                    method = "POST",
                    headers = { ["Content-Type"] = "application/json" },
                    body = [[{"messages":[{"role":"user","content":"debug my python"}]}]],
                }))
                return res.body
            end
            -- the first request creates the checkers; give them time to probe
            send()
            ngx.sleep(3)
            ngx.say(send())
        }
    }
--- timeout: 10
--- response_body
model-cheap
--- error_log
system_one routing: instance code is unhealthy



=== TEST 21: a rate-limited instance is skipped
--- config
    location /t {
        content_by_lua_block {
            local core = require("apisix.core")
            local t = require("lib.test_admin").test
            local function inst(name, model, description)
                -- the fixture server answers with usage, which
                -- ai-rate-limiting counts
                return {
                    name = name, provider = "openai", weight = 1,
                    auth = { header = { Authorization = "Bearer llm-token" } },
                    options = { model = model },
                    override = { endpoint = "http://127.0.0.1:1980/v1/chat/completions" },
                    description = description,
                }
            end
            local conf = {
                uri = "/limited",
                plugins = {
                    ["ai-proxy-multi"] = {
                        balancer = { algorithm = "system_one" },
                        system_one_opts = {
                            endpoint = "http://127.0.0.1:6796/v1/systemone",
                            model = "jev-latest",
                            fallback = "default",
                        },
                        fallback_strategy = { "rate_limiting" },
                        instances = {
                            inst("code", "model-code", "Programming and debugging."),
                            inst("cheap", "model-cheap", "Translation and summaries."),
                            inst("default", "model-fallback", "Everything else."),
                        },
                        ssl_verify = false,
                    },
                    ["ai-rate-limiting"] = {
                        instances = {
                            { name = "code", limit = 10, time_window = 60 },
                        },
                    },
                },
            }
            local code, body = t('/apisix/admin/routes/5', ngx.HTTP_PUT,
                                 core.json.encode(conf))
            if code >= 300 then
                ngx.status = code
                ngx.say(body)
                return
            end

            local http = require("resty.http")
            local uri = "http://127.0.0.1:" .. ngx.var.server_port .. "/limited"
            -- the first request spends the 10 tokens of `code`, so the second
            -- one goes to the next instance of the ranking
            for _ = 1, 2 do
                local httpc = http.new()
                local res = assert(httpc:request_uri(uri, {
                    method = "POST",
                    headers = {
                        ["Content-Type"] = "application/json",
                        ["X-AI-Fixture"] = "openai/chat-model-echo.json",
                    },
                    body = [[{"messages":[{"role":"user","content":"debug my python"}]}]],
                }))
                ngx.say(res.status, " ", core.json.decode(res.body).model)
            end
        }
    }
--- response_body
200 model-code
200 model-cheap
--- error_log
system_one routing: instance code is rate limited



=== TEST 22: the System One auth header is encrypted in etcd
--- yaml_config
apisix:
    data_encryption:
        enable_encrypt_fields: true
        keyring:
            - edd1c9f0985e76a2
--- config
    location /t {
        content_by_lua_block {
            local core = require("apisix.core")
            local json = require("toolkit.json")
            local t = require("lib.test_admin").test
            local conf = {
                uri = "/encrypted",
                plugins = {
                    ["ai-proxy-multi"] = {
                        balancer = { algorithm = "system_one" },
                        system_one_opts = {
                            endpoint = "http://127.0.0.1:6796/v1/systemone",
                            model = "jev-latest",
                            auth = { header = { Authorization = "Bearer s1-token" } },
                        },
                        instances = {
                            { name = "a", provider = "openai", weight = 1,
                              auth = { header = { Authorization = "Bearer x" } },
                              description = "A." },
                            { name = "b", provider = "openai", weight = 1,
                              auth = { header = { Authorization = "Bearer y" } },
                              description = "B." },
                        },
                    },
                },
            }
            local code, body = t('/apisix/admin/routes/3', ngx.HTTP_PUT,
                                 core.json.encode(conf))
            if code >= 300 then
                ngx.status = code
                ngx.say(body)
                return
            end
            ngx.sleep(0.5)

            local _, _, res = t('/apisix/admin/routes/3', ngx.HTTP_GET)
            res = json.decode(res)
            local opts = res.value.plugins["ai-proxy-multi"].system_one_opts
            ngx.say(opts.auth.header.Authorization)

            local etcd = require("apisix.core.etcd")
            local stored = assert(etcd.get('/routes/3'))
            opts = stored.body.node.value.plugins["ai-proxy-multi"].system_one_opts
            ngx.say(opts.auth.header.Authorization == "Bearer s1-token"
                    and "plaintext" or "encrypted")
        }
    }
--- response_body
Bearer s1-token
encrypted



=== TEST 23: reconfigure: failing top pick, the rest below the threshold
--- config
    location /t {
        content_by_lua_block {
            local core = require("apisix.core")
            local t = require("lib.test_admin").test
            local function inst(name, model, description, endpoint)
                return {
                    name = name, provider = "openai", weight = 1,
                    auth = { header = { Authorization = "Bearer llm-token" } },
                    options = { model = model },
                    override = { endpoint = endpoint
                                 or "http://127.0.0.1:6795/v1/chat/completions" },
                    description = description,
                }
            end
            local conf = {
                uri = "/anything",
                plugins = {
                    ["ai-proxy-multi"] = {
                        balancer = { algorithm = "system_one" },
                        system_one_opts = {
                            endpoint = "http://127.0.0.1:6796/v1/systemone",
                            model = "jev-latest",
                            fallback = "default",
                            threshold = 0.5,
                        },
                        fallback_strategy = { "http_5xx" },
                        instances = {
                            inst("code", "model-code", "Programming and debugging.",
                                 "http://127.0.0.1:6795/fail/v1/chat/completions"),
                            inst("cheap", "model-cheap", "Translation and summaries."),
                            inst("default", "model-fallback", "Everything else."),
                        },
                        ssl_verify = false,
                    },
                },
            }
            local code, body = t('/apisix/admin/routes/1', ngx.HTTP_PUT,
                                 core.json.encode(conf))
            if code >= 300 then
                ngx.status = code
                ngx.say(body)
                return
            end
            ngx.say("passed")
        }
    }
--- response_body
passed



=== TEST 24: the retry goes to the fallback, not to a runner-up below the threshold
--- request
POST /anything
{"model":"auto","messages":[{"role":"user","content":"debug my python"}]}
--- more_headers
Content-Type: application/json
--- response_body chomp
model-fallback
--- error_log
no untried available instance cleared the threshold, falling back to default
ai instance code returned status 500, falling back to default



=== TEST 25: reconfigure: every instance fails
--- config
    location /t {
        content_by_lua_block {
            local core = require("apisix.core")
            local t = require("lib.test_admin").test
            local function inst(name, model, description)
                return {
                    name = name, provider = "openai", weight = 1,
                    auth = { header = { Authorization = "Bearer llm-token" } },
                    options = { model = model },
                    override = {
                        endpoint = "http://127.0.0.1:6795/fail/v1/chat/completions",
                    },
                    description = description,
                }
            end
            local conf = {
                uri = "/anything",
                plugins = {
                    ["ai-proxy-multi"] = {
                        balancer = { algorithm = "system_one" },
                        system_one_opts = {
                            endpoint = "http://127.0.0.1:6796/v1/systemone",
                            model = "jev-latest",
                        },
                        fallback_strategy = { "http_5xx" },
                        instances = {
                            inst("code", "model-code", "Programming and debugging."),
                            inst("cheap", "model-cheap", "Translation and summaries."),
                            inst("default", "model-fallback", "Everything else."),
                        },
                        ssl_verify = false,
                    },
                },
            }
            local code, body = t('/apisix/admin/routes/1', ngx.HTTP_PUT,
                                 core.json.encode(conf))
            if code >= 300 then
                ngx.status = code
                ngx.say(body)
                return
            end
            ngx.say("passed")
        }
    }
--- response_body
passed



=== TEST 26: each instance is tried once, then the request fails
--- request
POST /anything
{"model":"auto","messages":[{"role":"user","content":"debug my python"}]}
--- more_headers
Content-Type: application/json
--- error_code: 502
--- error_log
ai instance code returned status 500, falling back to cheap
ai instance cheap returned status 500, falling back to default
failed to pick new AI instance: all servers tried
--- grep_error_log eval
qr/s1-recv-state:/
--- grep_error_log_out
s1-recv-state:
