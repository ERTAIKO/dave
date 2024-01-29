local Hash = require "cryptography.hash"
local eth_abi = require "utils.eth_abi"

local function parse_topics(json)
    local _, _, topics = json:find(
        [==["topics":%[([^%]]*)%]]==]
    )

    local t = {}
    for k, _ in string.gmatch(topics, [["(0x%x+)"]]) do
        table.insert(t, k)
    end

    return t
end

local function parse_data(json, sig)
    local _, _, data = json:find(
        [==["data":"(0x%x+)"]==]
    )

    local decoded_data = eth_abi.decode_event_data(sig, data)
    return decoded_data
end

local function parse_meta(json)
    local _, _, block_hash = json:find(
        [==["blockHash":"(0x%x+)"]==]
    )

    local _, _, block_number = json:find(
        [==["blockNumber":"(0x%x+)"]==]
    )

    local _, _, log_index = json:find(
        [==["logIndex":"(0x%x+)"]==]
    )

    local t = {
        block_hash = block_hash,
        block_number = tonumber(block_number),
        log_index = tonumber(log_index),
    }

    return t
end


local function parse_logs(logs, data_sig)
    local ret = {}
    for k, _ in string.gmatch(logs, [[{[^}]*}]]) do
        local emited_topics = parse_topics(k)
        local decoded_data = parse_data(k, data_sig)
        local meta = parse_meta(k)
        table.insert(ret, { emited_topics = emited_topics, decoded_data = decoded_data, meta = meta })
    end

    return ret
end

local CommitmentClock = {}
CommitmentClock.__index = CommitmentClock

function CommitmentClock:new(allowance, last_resume, block_time)
    local clock = {
        allowance = tonumber(allowance),
        last_resume = tonumber(last_resume),
        block_time = tonumber(block_time)
    }

    setmetatable(clock, self)
    return clock
end

function CommitmentClock:__tostring()
    local c = self
    local b = c.block_time
    local s
    if c.last_resume == 0 then
        local time_left = c.allowance
        s = string.format("clock paused, %d seconds left", time_left)
    else
        local current = b
        local time_left = c.allowance - (current - c.last_resume)
        if time_left >= 0 then
            s = string.format("clock running, %d seconds left", time_left)
        else
            s = string.format("clock running, %d seconds overdue", -time_left)
        end
    end
    return s
end

function CommitmentClock:has_time()
    local clock = self
    if clock.last_resume == 0 then
        return true
    else
        local current = clock.block_time
        return (clock.last_resume + clock.allowance) > current
    end
end

function CommitmentClock:time_since_timeout()
    local clock = self
    if clock.last_resume == 0 then
        return
    else
        local current = clock.block_time
        return current - (clock.last_resume + clock.allowance)
    end
end

local Reader = {}
Reader.__index = Reader

function Reader:new()
    local blockchain_data = require "blockchain.constants"

    local reader = {
        endpoint = blockchain_data.endpoint
    }

    setmetatable(reader, self)
    return reader
end

function Reader:_get_block(block)
    local cmd = string.format("cast block " .. block .. " 2>&1")

    local handle = io.popen(cmd)
    assert(handle)

    local ret
    local str = handle:read "*a"
    if str:find "Error" or str:find "error" then
        handle:close()
        error(string.format("Cast block failed:\n%s", str))
    end

    ret = str:match("timestamp            (%d+)")
    handle:close()

    return ret
end

local cast_logs_template = [==[
cast rpc -r "%s" eth_getLogs \
    '[{"fromBlock": "earliest", "toBlock": "latest", "address": "%s", "topics": [%s]}]' -w  2>&1
]==]

function Reader:_read_logs(tournament_address, sig, topics, data_sig)
    topics = topics or { false, false, false }
    local encoded_sig = eth_abi.encode_sig(sig)
    table.insert(topics, 1, encoded_sig)
    assert(#topics == 4, "topics doesn't have four elements")

    local topics_strs = {}
    for _, v in ipairs(topics) do
        local s
        if v then
            s = '"' .. v .. '"'
        else
            s = "null"
        end
        table.insert(topics_strs, s)
    end
    local topic_str = table.concat(topics_strs, ", ")

    local cmd = string.format(
        cast_logs_template,
        self.endpoint,
        tournament_address,
        topic_str
    )

    local handle = io.popen(cmd)
    assert(handle)
    local logs = handle:read "*a"
    handle:close()

    if logs:find "Error" then
        error(string.format("Read logs `%s` failed:\n%s", sig, logs))
    end

    local ret = parse_logs(logs, data_sig)
    return ret
end

local cast_call_template = [==[
cast call --rpc-url "%s" "%s" "%s" %s 2>&1
]==]

function Reader:_call(address, sig, args)
    local quoted_args = {}
    for _, v in ipairs(args) do
        table.insert(quoted_args, '"' .. v .. '"')
    end
    local args_str = table.concat(quoted_args, " ")

    local cmd = string.format(
        cast_call_template,
        self.endpoint,
        address,
        sig,
        args_str
    )

    local handle = io.popen(cmd)
    assert(handle)

    local ret = {}
    local str = handle:read()
    while str do
        if str:find "Error" or str:find "error" then
            local err_str = handle:read "*a"
            handle:close()
            error(string.format("Call `%s` failed:\n%s%s", sig, str, err_str))
        end

        table.insert(ret, str)
        str = handle:read()
    end
    handle:close()

    return ret
end

function Reader:read_match_created(tournament_address)
    local sig = "matchCreated(bytes32,bytes32,bytes32)"
    local data_sig = "(bytes32)"

    local logs = self:_read_logs(tournament_address, sig, { false, false, false }, data_sig)

    local ret = {}
    for k, v in ipairs(logs) do
        local log = {}
        log.tournament_address = tournament_address
        log.meta = v.meta

        log.commitment_one = Hash:from_digest_hex(v.emited_topics[2])
        log.commitment_two = Hash:from_digest_hex(v.emited_topics[3])
        log.left_hash = Hash:from_digest_hex(v.decoded_data[1])
        log.match_id_hash = log.commitment_one:join(log.commitment_two)

        ret[k] = log
    end

    return ret
end

function Reader:read_commitment_joined(tournament_address)
    local sig = "commitmentJoined(bytes32)"
    local data_sig = "(bytes32)"

    local logs = self:_read_logs(tournament_address, sig, { false, false, false }, data_sig)

    local ret = {}
    for k, v in ipairs(logs) do
        local log = {}
        log.tournament_address = tournament_address
        log.meta = v.meta
        log.root = Hash:from_digest_hex(v.decoded_data[1])

        ret[k] = log
    end

    return ret
end

function Reader:read_commitment(tournament_address, commitment_hash)
    local sig = "getCommitment(bytes32)((uint64,uint64),bytes32)"

    local call_ret = self:_call(tournament_address, sig, { commitment_hash:hex_string() })
    assert(#call_ret == 2)

    -- call_ret[1] = (299, 0) or (419, 1700743849 [1.7e9])
    -- remove spaces, scientific notations and color code
    local parsed_ret = call_ret[1]:gsub("%s+", ""):gsub("%b[]", ""):gsub("\27%[[%d;]*m", "")
    local allowance, last_resume = parsed_ret:match "%((%d+),(%d+)%)"
    assert(allowance)
    assert(last_resume)

    local block_time = self:_get_block("latest")

    local ret = {
        clock = CommitmentClock:new(allowance, last_resume, block_time),
        final_state = Hash:from_digest_hex(call_ret[2]),
    }

    return ret
end

function Reader:read_constants(tournament_address)
    local sig = "tournamentLevelConstants()(uint64,uint64,uint64,uint64)"

    local call_ret = self:_call(tournament_address, sig, { })
    assert(#call_ret == 4)

    local ret = {
        max_level = tonumber(call_ret[1]),
        level = tonumber(call_ret[2]),
        log2_step = tonumber(call_ret[3]),
        height = tonumber(call_ret[4]),
    }

    return ret
end

function Reader:read_tournament_created(tournament_address, match_id_hash)
    local sig = "newInnerTournament(bytes32,address)"
    local data_sig = "(address)"

    local logs = self:_read_logs(tournament_address, sig, { match_id_hash:hex_string(), false, false }, data_sig)
    assert(#logs <= 1)

    if #logs == 0 then return false end
    local log = logs[1]

    local ret = {
        parent_match = match_id_hash,
        new_tournament = log.decoded_data[1],
    }

    return ret
end

function Reader:match(address, match_id_hash)
    local sig = "getMatch(bytes32)(bytes32,bytes32,bytes32,uint256,uint64,uint64)"
    local ret = self:_call(address, sig, { match_id_hash:hex_string() })
    ret[1] = Hash:from_digest_hex(ret[1])
    ret[2] = Hash:from_digest_hex(ret[2])
    ret[3] = Hash:from_digest_hex(ret[3])

    return ret
end

function Reader:inner_tournament_winner(address)
    local sig = "innerTournamentWinner()(bool,bytes32,bytes32)"
    local ret = self:_call(address, sig, {})
    ret[2] = Hash:from_digest_hex(ret[2])
    ret[3] = Hash:from_digest_hex(ret[3])

    return ret
end

function Reader:root_tournament_winner(address)
    local sig = "arbitrationResult()(bool,bytes32,bytes32)"
    local ret = self:_call(address, sig, {})
    ret[2] = Hash:from_digest_hex(ret[2])
    ret[3] = Hash:from_digest_hex(ret[3])

    return ret
end

return Reader
