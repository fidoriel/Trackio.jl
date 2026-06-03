const BATCH_SEND_INTERVAL = 0.5
const MAX_BACKOFF = 30.0

function start_queue(run::Run)
    channel = Channel{QueueItem}(1024)
    stop_requested = Ref(false)
    queue =
        LogQueue(channel, Task(() -> nothing), stop_requested, QueueItem[], Set{String}())
    task = @async queue_sender(run, queue)
    queue.task = task
    return queue
end

function enqueue(run::Run, item::QueueItem)
    run.closed && error("Cannot log to a finished Trackio run")
    put!(run.queue.channel, item)
    return nothing
end

function queue_sender(run::Run, queue::LogQueue)
    backoff = BATCH_SEND_INTERVAL
    while true
        drain_queue!(queue)
        if !isempty(queue.pending)
            try
                send_pending!(run, queue)
                backoff = BATCH_SEND_INTERVAL
            catch err
                warn_once!(
                    queue,
                    "send",
                    "trackio failed to send logs: $err. Retrying in the background.",
                )
                sleep(backoff)
                backoff = min(MAX_BACKOFF, backoff * 2)
                continue
            end
        end

        if queue.stop_requested[]
            drain_queue!(queue)
            isempty(queue.pending) && break
            continue
        end
        sleep(BATCH_SEND_INTERVAL)
    end
end

function drain_queue!(queue::LogQueue)
    while isready(queue.channel)
        push!(queue.pending, take!(queue.channel))
    end
    return queue
end

function send_pending!(run::Run, queue::LogQueue)
    run.client === nothing && error("remote client is not configured")
    logs = Dict{String,Any}[]
    system_logs = Dict{String,Any}[]
    alerts = Dict{String,Any}[]
    uploads = Dict{String,Any}[]
    for item in queue.pending
        if item.kind == :log
            push!(logs, item.payload)
        elseif item.kind == :system_log
            push!(system_logs, item.payload)
        elseif item.kind == :alert
            push!(alerts, item.payload)
        elseif item.kind == :upload
            push!(uploads, item.payload)
        end
    end

    if !isempty(logs)
        predict(run.client, "/bulk_log"; logs = logs, hf_token = run.client.hf_token)
    end
    if !isempty(system_logs)
        predict(
            run.client,
            "/bulk_log_system";
            logs = system_logs,
            hf_token = run.client.hf_token,
        )
    end
    if !isempty(uploads)
        predict(
            run.client,
            "/bulk_upload_media";
            uploads = uploads,
            hf_token = run.client.hf_token,
        )
    end
    if !isempty(alerts)
        predict(run.client, "/bulk_alert"; alerts = alerts, hf_token = run.client.hf_token)
    end
    empty!(queue.pending)
    return nothing
end

function warn_once!(queue::LogQueue, key::String, message::String)
    key in queue.warned_failures && return nothing
    push!(queue.warned_failures, key)
    @warn message
    return nothing
end

function finish_queue!(run::Run; timeout_seconds = 30.0)
    queue = run.queue
    queue === nothing && return nothing
    queue.stop_requested[] = true
    deadline = time() + timeout_seconds
    while time() < deadline
        if istaskdone(queue.task)
            break
        end
        sleep(0.05)
    end
    if !istaskdone(queue.task)
        @warn "trackio.finish() timed out waiting for pending logs to flush"
    end
    return nothing
end
