max_threads_count = ENV.fetch("RAILS_MAX_THREADS") { 5 }
min_threads_count = ENV.fetch("RAILS_MIN_THREADS") { max_threads_count }
threads min_threads_count, max_threads_count

port        ENV.fetch("PORT") { 3000 }
environment ENV.fetch("RAILS_ENV") { "development" }
pidfile     ENV.fetch("PIDFILE") { "tmp/pids/server.pid" }

workers ENV.fetch("WEB_CONCURRENCY") { 2 }
preload_app!

worker_timeout 60
worker_shutdown_timeout 8

before_fork do
  ActiveRecord::Base.connection_pool.disconnect! if defined?(ActiveRecord)
  # Native ONNX inference sessions don't survive `fork`; drop anything built during
  # preload so each worker rebuilds its own healthy session in on_worker_boot.
  Stacks::Etl::Embedder.reset! if defined?(Stacks::Etl::Embedder)
end

on_worker_boot do
  ActiveRecord::Base.establish_connection if defined?(ActiveRecord)
  # Preload the local embedding model so the FIRST semantic/hybrid MCP `search`
  # doesn't pay the multi-second ONNX cold start synchronously — which made the
  # initial query time out. Done in a background thread so a slow first-ever model
  # download can't block the worker from accepting connections (worker_timeout /
  # Heroku boot). See docs/meet-etl-deploy.md and Stacks::Etl::Embedder.warm!.
  Thread.new { Stacks::Etl::Embedder.warm! } if defined?(Stacks::Etl::Embedder)
end

plugin :tmp_restart
