--- @diagnostic disable: invisible, missing-fields, assign-type-mismatch, cast-local-type, param-type-mismatch
local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")

local Config = require("agentic.config")
local Logger = require("agentic.utils.logger")
local SessionRegistry = require("agentic.session_registry")
local AgentInstance = require("agentic.acp.agent_instance")

describe("agentic: switch_provider", function()
    --- @type TestStub
    local get_instance_stub
    --- @type TestStub
    local logger_notify_stub
    local original_provider

    before_each(function()
        original_provider = Config.provider
        logger_notify_stub = spy.stub(Logger, "notify")

        -- Mock AgentInstance globally for all tests
        get_instance_stub = spy.stub(AgentInstance, "get_instance")

        -- Create a function that returns the appropriate agent based on provider
        local function get_fake_agent(provider_name)
            local agent_name = provider_name or "TestProvider"
            --- @type agentic.acp.ACPClient
            local fake_agent = {}

            fake_agent.state = "ready"
            fake_agent.provider_config = {
                name = agent_name,
                initial_model = nil,
                default_mode = nil,
            }
            fake_agent.agent_info = {}

            -- Mock create_session method
            function fake_agent:create_session(_handlers, callback)
                vim.schedule(function()
                    callback({
                        sessionId = "test-session-" .. agent_name,
                        configOptions = nil,
                        modes = nil,
                        models = nil,
                    })
                end)
            end

            function fake_agent:cancel_session() end

            return fake_agent
        end

        get_instance_stub:invokes(function(provider_name, callback)
            local fake_agent = get_fake_agent(provider_name)
            if callback then
                vim.schedule(function()
                    callback(fake_agent)
                end)
            end
            return fake_agent
        end)
    end)

    after_each(function()
        Config.provider = original_provider
        logger_notify_stub:revert()
        if get_instance_stub then
            get_instance_stub:revert()
            get_instance_stub = nil
        end

        -- Clean up any sessions created during tests
        for tab_id, _ in pairs(SessionRegistry.sessions) do
            SessionRegistry.destroy_session(tab_id)
        end
    end)

    it("can create a session with mocked agent", function()
        local SessionManager = require("agentic.session_manager")
        local tab_page_id = vim.api.nvim_get_current_tabpage()

        local session = SessionManager:new(tab_page_id) --[[@as agentic.SessionManager]]
        assert.is_not_nil(session)
    end)

    it("restores chat history messages after switching provider", function()
        -- Setup: Create initial session with messages manually
        local tab_page_id = vim.api.nvim_get_current_tabpage()
        local SessionManager = require("agentic.session_manager")

        -- Create initial session manually
        local session = SessionManager:new(tab_page_id) --[[@as agentic.SessionManager]]
        assert.is_not_nil(session)

        -- Wait for async callbacks (agent ready -> new_session)
        vim.wait(100, function()
            return false
        end)

        SessionRegistry.sessions[tab_page_id] = session

        -- Manually set session_id and initialize chat_history
        session.session_id = "old-session-id" --[[@as string]]
        local message1 = {
            type = "user",
            text = "hello",
            timestamp = os.time(),
            provider_name = "OriginalProvider",
        } --[[@as agentic.ui.ChatHistory.Message]]
        session.chat_history:add_message(message1)

        local message2 = {
            type = "agent",
            text = "hi there",
            timestamp = os.time(),
            provider_name = "OriginalProvider",
        } --[[@as agentic.ui.ChatHistory.Message]]
        session.chat_history:add_message(message2)

        -- Get initial message count
        local initial_message_count = #session.chat_history.messages
        assert.equal(2, initial_message_count)

        -- Now do the provider switch
        local Agentic = require("agentic")
        Config.provider = "NewProvider"
        Agentic.switch_provider({ provider = "NewProvider" })

        -- Allow async callbacks to fire
        vim.wait(100, function()
            return false
        end)

        -- Get new session
        local new_session = SessionRegistry.sessions[tab_page_id] --[[@as agentic.SessionManager]]
        assert.is_not_nil(new_session)

        -- CRITICAL TEST: Verify history messages were restored
        -- This test will fail if replay_history_messages wasn't called
        -- or if on_session_ready didn't fire
        assert.equal(initial_message_count, #new_session.chat_history.messages)

        -- Verify message content is correct
        assert.equal("user", new_session.chat_history.messages[1].type)
        assert.equal("hello", new_session.chat_history.messages[1].text)
        assert.equal("agent", new_session.chat_history.messages[2].type)
        assert.equal("hi there", new_session.chat_history.messages[2].text)

        -- Verify history_to_send was set for next prompt
        assert.equal(
            initial_message_count,
            #(new_session.history_to_send or {})
        )
    end)

    it("blocks switch when session is initializing", function()
        local Agentic = require("agentic")
        local SessionManager = require("agentic.session_manager")
        local tab_page_id = vim.api.nvim_get_current_tabpage()

        -- Create session with no session_id (initializing state)
        local session = SessionManager:new(tab_page_id) --[[@as agentic.SessionManager]]
        assert.is_not_nil(session)
        assert.is_nil(session.session_id) -- Not initialized yet
        SessionRegistry.sessions[tab_page_id] = session

        -- Try to switch
        Agentic.switch_provider({ provider = "TestProvider" })

        -- Should notify user about initialization
        assert.spy(logger_notify_stub).was.called()
        local msg = logger_notify_stub.calls[1][1]
        assert.truthy(msg:match("[Ii]nitializ"))
    end)

    it("blocks switch when generating", function()
        local Agentic = require("agentic")
        local SessionManager = require("agentic.session_manager")
        local tab_page_id = vim.api.nvim_get_current_tabpage()

        -- Create initialized session
        local session = SessionManager:new(tab_page_id) --[[@as agentic.SessionManager]]
        session.session_id = "test-session-id" --[[@as string]]
        session.is_generating = true -- Set generating flag
        SessionRegistry.sessions[tab_page_id] = session

        -- Try to switch
        Agentic.switch_provider({ provider = "TestProvider" })

        -- Should notify user
        assert.spy(logger_notify_stub).was.called()
        local msg = logger_notify_stub.calls[1][1]
        assert.truthy(msg:match("[Gg]enerating"))
    end)
end)
