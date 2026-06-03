# trackio.jl

This project is a port of the trackio lib to julia.

We use a formatter - make format

logging should not be blocking. Use channels and a separate thread which then does the http communication.
