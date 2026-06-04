# trackio.jl

This is a trackio client for julia. 
It was ported with ai from py to jl.

## Demo

By default, Trackio.jl logs locally to the same SQLite directory used by Python
Trackio:

```julia
using Trackio

run = Trackio.init("julia-client-demo-project"; name = "local-demo")
Trackio.log(run, Dict("loss" => 0.5))
Trackio.finish(run)
```

Open the Python dashboard against the same local data:

```sh
uv tool run trackio show --project julia-client-demo-project
```

If you want to try a local self hosted server:

```sh
uv venv
uv pip install trackio
uv run python -c 'import trackio.server as server; server.write_token = "dev-token"; import trackio; trackio.show(project="julia-client-demo-project", host="127.0.0.1", server_port=7860, open_browser=False)'
```

```sh
export TRACKIO_SERVER_URL="http://127.0.0.1:7860"
export TRACKIO_WRITE_TOKEN="dev-token"
```

Remote logging must opt in with `report_to = :remote`. The
`examples/log_everything.jl` demo does this for you.

Alternatively, if you want to log to a Hugging Face Space instead of a local server:

```sh
export TRACKIO_SPACE_ID="your-user/your-trackio-space"
export HF_TOKEN="hf_..."
```
Run the example

```sh
julia --project=. examples/log_everything.jl
```

## Dev

```sh
make format
```
