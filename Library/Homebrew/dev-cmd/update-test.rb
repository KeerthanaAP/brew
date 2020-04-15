# frozen_string_literal: true

require "cli/parser"

module Homebrew
  module_function

  def update_test_args
    Homebrew::CLI::Parser.new do
      usage_banner <<~EOS
        `update-test` [<options>]

        Run a test of `brew update` with a new repository clone.
        If no options are passed, use `origin/master` as the start commit.
      EOS
      switch "--to-tag",
             description: "Set `HOMEBREW_UPDATE_TO_TAG` to test updating between tags."
      switch "--keep-tmp",
             description: "Retain the temporary directory containing the new repository clone."
      flag   "--commit=",
             description: "Use the specified <commit> as the start commit."
      flag   "--before=",
             description: "Use the commit at the specified <date> as the start commit."
      switch :verbose
      switch :debug
      max_named 0
    end
  end

  def update_test
    update_test_args.parse

    ENV["HOMEBREW_UPDATE_TEST"] = "1"

    branch = if args.to_tag?
      ENV["HOMEBREW_UPDATE_TO_TAG"] = "1"
      "stable"
    else
      "master"
    end

    start_commit, end_commit = nil
    cd HOMEBREW_REPOSITORY do
      start_commit = if commit = args.commit
        commit
      elsif date = args.before
        Utils.popen_read("git", "rev-list", "-n1", "--before=#{date}", "origin/master").chomp
      elsif args.to_tag?
        tags = Utils.popen_read("git", "tag", "--list", "--sort=-version:refname")
        if tags.blank?
          tags = if (HOMEBREW_REPOSITORY/".git/shallow").exist?
            safe_system "git", "fetch", "--tags", "--depth=1"
            Utils.popen_read("git", "tag", "--list", "--sort=-version:refname")
          elsif OS.linux?
            Utils.popen_read("git tag --list | sort -rV")
          end
        end
        current_tag, previous_tag, = tags.lines
        current_tag = current_tag.to_s.chomp
        odie "Could not find current tag in:\n#{tags}" if current_tag.empty?
        # ^0 ensures this points to the commit rather than the tag object.
        end_commit = "#{current_tag}^0"

        previous_tag = previous_tag.to_s.chomp
        odie "Could not find previous tag in:\n#{tags}" if previous_tag.empty?
        # ^0 ensures this points to the commit rather than the tag object.
        "#{previous_tag}^0"
      else
        Utils.popen_read("git", "rev-parse", "origin/master").chomp
      end
      odie "Could not find start commit!" if start_commit.empty?

      start_commit = Utils.popen_read("git", "rev-parse", start_commit).chomp
      odie "Could not find start commit!" if start_commit.empty?

      end_commit ||= "HEAD"
      end_commit = Utils.popen_read("git", "rev-parse", end_commit).chomp
      odie "Could not find end commit!" if end_commit.empty?

      if Utils.popen_read("git", "branch", "--list", "master").blank?
        safe_system "git", "branch", "master", "origin/master"
      end
    end

    puts "Start commit: #{start_commit}"
    puts "  End commit: #{end_commit}"

    mkdir "update-test"
    chdir "update-test" do
      curdir = Pathname.new(Dir.pwd)

      oh1 "Preparing test environment..."
      # copy Homebrew installation
      safe_system "git", "clone", "#{HOMEBREW_REPOSITORY}/.git", ".",
                  "--branch", "master", "--single-branch"

      # set git origin to another copy
      safe_system "git", "clone", "#{HOMEBREW_REPOSITORY}/.git", "remote.git",
                  "--bare", "--branch", "master", "--single-branch"
      safe_system "git", "config", "remote.origin.url", "#{curdir}/remote.git"

      # force push origin to end_commit
      safe_system "git", "checkout", "-B", "master", end_commit
      safe_system "git", "push", "--force", "origin", "master"

      # set test copy to start_commit
      safe_system "git", "reset", "--hard", start_commit

      # update ENV["PATH"]
      ENV["PATH"] = PATH.new(ENV["PATH"]).prepend(curdir/"bin")

      # run brew update
      oh1 "Running brew update..."
      safe_system "brew", "update", "--verbose"
      actual_end_commit = Utils.popen_read("git", "rev-parse", branch).chomp
      if actual_end_commit != end_commit
        raise <<~EOS
          brew update didn't update #{branch}!
          Start commit:        #{start_commit}
          Expected end commit: #{end_commit}
          Actual end commit:   #{actual_end_commit}
        EOS
      end
    end
  ensure
    FileUtils.rm_rf "update-test" unless Homebrew.args.keep_tmp?
  end
end
