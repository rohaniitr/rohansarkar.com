#!/usr/bin/env bash
# Run the site locally for testing.
# Usage: ./serve.sh

set -e
cd "$(dirname "$0")"

# Use Homebrew Ruby if available (for Ruby 4+)
if [ -d "/opt/homebrew/opt/ruby/bin" ]; then
  export PATH="/opt/homebrew/opt/ruby/bin:$PATH"
fi

echo "Installing dependencies..."
bundle install

echo "Starting Jekyll server..."
echo "Open http://localhost:4000 in your browser."
echo ""
bundle exec jekyll serve
