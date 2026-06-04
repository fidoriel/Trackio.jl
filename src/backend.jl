struct RemoteBackend <: LogBackend
    client::TrackioClient
end

struct LocalBackend <: LogBackend
    db_path::String
    project::String
end

function flush_batch!(
    backend::RemoteBackend,
    logs::Vector{Dict{String,Any}},
    system_logs::Vector{Dict{String,Any}},
    alerts::Vector{Dict{String,Any}},
    uploads::Vector{Dict{String,Any}},
)
    client = backend.client
    if !isempty(logs)
        predict(client, "/bulk_log"; logs = logs, hf_token = client.hf_token)
    end
    if !isempty(system_logs)
        predict(client, "/bulk_log_system"; logs = system_logs, hf_token = client.hf_token)
    end
    if !isempty(uploads)
        predict(client, "/bulk_upload_media"; uploads = uploads, hf_token = client.hf_token)
    end
    if !isempty(alerts)
        predict(client, "/bulk_alert"; alerts = alerts, hf_token = client.hf_token)
    end
    return nothing
end

function flush_batch!(
    ::LocalBackend,
    logs::Vector{Dict{String,Any}},
    system_logs::Vector{Dict{String,Any}},
    alerts::Vector{Dict{String,Any}},
    uploads::Vector{Dict{String,Any}},
)
    write_local_batch!(logs, system_logs, alerts)
    return nothing
end

function prepare_media end
