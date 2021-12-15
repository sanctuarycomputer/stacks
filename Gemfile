source 'https://rubygems.org'
git_source(:github) { |repo| "https://github.com/#{repo}.git" }

ruby '2.7.1'

gem 'rails', '~> 6.0.3', '>= 6.0.3.4'
gem 'pg', '>= 0.18', '< 2.0'
gem 'puma', '~> 4.1'
gem 'sass-rails', '>= 6'
gem 'webpacker', '~> 4.0'
gem 'turbolinks', '~> 5'
gem 'bootsnap', '>= 1.4.2', require: false
gem 'activeadmin'
gem 'devise', github: 'heartcombo/devise', branch: 'ca-omniauth-2'
gem 'omniauth-google-oauth2'
gem 'omniauth-rails_csrf_protection'
gem 'intuit-oauth'
gem 'acts_as_paranoid', '~> 0.7.0'
gem 'sentry-ruby'
gem 'sentry-rails'
gem 'httparty'
gem 'quickbooks-ruby'
gem 'order_as_specified'
gem 'validate_url'

group :development, :test do
  gem 'pry'
end

group :development do
  gem 'web-console', '>= 3.3.0'
  gem 'listen', '~> 3.2'
  gem 'spring'
  gem 'spring-watcher-listen', '~> 2.0.0'
end

group :test do
  gem 'capybara', '>= 2.15'
  gem 'selenium-webdriver'
  gem 'webdrivers'
end

gem 'tzinfo-data', platforms: [:mingw, :mswin, :x64_mingw, :jruby]
