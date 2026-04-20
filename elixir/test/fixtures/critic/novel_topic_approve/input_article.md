# Erlang :persistent_term caveats

`:persistent_term` is a global, per-VM cache optimized for read-heavy
workloads where the stored term almost never changes. Every write triggers
a full global GC scan of all processes holding references to the old term
— which can freeze large nodes for seconds. Use it only for constants
fixed at boot.
