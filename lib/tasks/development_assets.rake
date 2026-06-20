# frozen_string_literal: true

namespace :assets do
  task :prevent_development_precompile do
    next unless Rails.env.development?
    next if ENV["ALLOW_DEVELOPMENT_ASSET_PRECOMPILE"] == "1"

    abort <<~MESSAGE
      Refusing to precompile assets in development.

      Precompiled files in public/assets shadow importmap/source assets and can
      make JavaScript changes look stale. Use bin/dev for local development.

      If you intentionally need this, rerun with:
        ALLOW_DEVELOPMENT_ASSET_PRECOMPILE=1 bin/rails assets:precompile
    MESSAGE
  end
end

precompile_task = Rake::Task["assets:precompile"]
precompile_task.prerequisites.delete("assets:prevent_development_precompile")
precompile_task.prerequisites.unshift("assets:prevent_development_precompile")
