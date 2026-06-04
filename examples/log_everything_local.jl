using Trackio
using Dates

const PROJECT = "julia-client-random-local"

asset(name) = joinpath(@__DIR__, "assets", name)

function main()
    run = Trackio.init(
        PROJECT;
        name = "random-local-demo",
        group = "examples",
        report_to = :local,
        config = Dict(
            "client" => "trackio.jl",
            "example" => basename(@__FILE__),
            "assets" => Dict(
                "license" => "CC0-1.0",
                "source" => "Self-generated with ffmpeg lavfi test sources and a hand-written YAML file.",
            ),
            "environment" => Dict(
                "cpu_arch" => string(Sys.ARCH),
                "cpu_threads" => Sys.CPU_THREADS,
                "kernel" => string(Sys.KERNEL),
                "driver" => get(ENV, "TRACKIO_DEMO_DRIVER", "none"),
            ),
            "model" => Dict(
                "name" => "tiny-linear-demo",
                "parameters" => 128,
                "optimizer" => "sgd",
            ),
            "started_at" => string(now(UTC)),
        ),
    )

    try
        rows = Dict{String,Any}[]
        for step = 0:5
            loss = round(1.0 / (step + 1) + 0.03 * sin(step); digits = 4)
            accuracy = round(0.52 + 0.075 * step; digits = 4)
            learning_rate = round(0.01 * 0.85^step; digits = 6)

            push!(
                rows,
                Dict(
                    "step" => step,
                    "loss" => loss,
                    "accuracy" => accuracy,
                    "learning_rate" => learning_rate,
                ),
            )

            Trackio.log(
                run,
                Dict(
                    "loss" => loss,
                    "accuracy" => accuracy,
                    "learning_rate" => learning_rate,
                    "validation" => Dict(
                        "loss" => round(loss * 1.08; digits = 4),
                        "accuracy" => round(accuracy - 0.025; digits = 4),
                    ),
                    "epoch_label" => "epoch-$step",
                );
                step = step,
            )
        end

        demo_trace = Trackio.Trace(
            [
                Dict("role" => "system", "content" => "You are a compact demo assistant."),
                Dict("role" => "user", "content" => "Summarize what was logged."),
                Dict(
                    "role" => "assistant",
                    "content" => "Metrics, graphs, table, trace, image, audio, video, yaml artifact, system log, and alert.",
                ),
            ];
            metadata = Dict("model" => "demo-chat", "latency_ms" => 12),
        )

        Trackio.log(
            run,
            Dict(
                "summary_table" => Trackio.Table(rows = rows),
                "conversation_trace" => demo_trace,
                "demo_image" => Trackio.Image(
                    asset("demo_image.png");
                    caption = "Self-generated PNG test image",
                ),
                "demo_audio" => Trackio.Audio(
                    asset("demo_audio.wav");
                    caption = "Self-generated 1 second 440 Hz WAV tone",
                ),
                "demo_video" => Trackio.Video(
                    asset("demo_video.mp4");
                    caption = "Self-generated MP4 test pattern",
                ),
            );
            step = 6,
        )

        Trackio.log_system(
            run,
            Dict(
                "host" => gethostname(),
                "julia_version" => string(VERSION),
                "total_memory_bytes" => Sys.total_memory(),
                "free_memory_bytes" => Sys.free_memory(),
                "example_finished_at" => string(now(UTC)),
            ),
        )

        Trackio.alert(
            run,
            "trackio.jl example completed";
            text = "The log_everything demo finished and queued all demo payloads.",
            level = :info,
            step = 6,
        )
    finally
        Trackio.finish(run)
    end

    println("Logged run: $(run.project) / $(run.name)")
    println("Local database: $(Trackio.project_db_path(PROJECT))")
    println("Open dashboard: uv tool run trackio show --project $PROJECT")
end

main()
