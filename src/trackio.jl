module trackio

using Dates
using HTTP
using JSON3
using UUIDs

export Run,
    Audio,
    Image,
    Table,
    TrackioClient,
    Trace,
    Video,
    alert,
    finish,
    host_is_hf_space,
    init,
    log,
    log_system,
    normalize_src,
    parse_trackio_server_url,
    predict,
    resolve_src_url,
    save,
    space_id_to_url,
    supports_http_api

include("types.jl")
include("serialization.jl")
include("client.jl")
include("queue.jl")
include("alerts.jl")
include("media.jl")
include("run.jl")

end
