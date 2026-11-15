web: env SOLID_QUEUE_IN_PUMA=false bundle exec puma -t 5:5 -p 5000 -e production
worker: bundle exec bin/jobs
release: bundle exec rails db:migrate
