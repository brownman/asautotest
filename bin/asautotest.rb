#!/usr/bin/env ruby
# -*- coding: utf-8 -*-
# asautotest --- automatically compile and test ActionScript code
# Copyright (C) 2010  Go Interactive

# This file is part of ASAutotest.

# ASAutotest is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.

# ASAutotest is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.

# You should have received a copy of the GNU General Public License
# along with ASAutotest.  If not, see <http://www.gnu.org/licenses/>.

require "rubygems"
require "pathname"
require "tmpdir"

module ASAutotest
  current_directory = File.dirname(Pathname.new(__FILE__).realpath)
  ROOT = File.expand_path(File.join(current_directory, ".."))
end

$: << File.join(ASAutotest::ROOT, "lib")

ENV["ASAUTOTEST_ROOT"] = ASAutotest::ROOT

require "asautotest/compilation-output-parser"
require "asautotest/compilation-result"
require "asautotest/compilation-runner"
require "asautotest/compiler-shell"
require "asautotest/logging"
require "asautotest/problematic-file"
require "asautotest/stopwatch"
require "asautotest/test-runner"
require "asautotest/utilities"

module ASAutotest
  FCSH = ENV["FCSH"] || "fcsh"
  FLASHPLAYER = ENV["FLASHPLAYER"] || "flashplayer"
  WATCH_GLOB = "**/[^.]*.{as,mxml}"
  DEFAULT_TEST_PORT = 50102
  GROWL_ERROR_TOKEN = "ASAutotest-#{ARGV.inspect.hash}"

  class << self
    attr_accessor :growl_enabled
    attr_accessor :displaying_growl_error
  end

  class CompilationRequest
    attr_reader :source_file_name
    attr_reader :source_directories
    attr_reader :library_file_names
    attr_reader :test_port
    attr_reader :output_file_name

    def production? ; @production end
    def test? ; @test end
    def temporary_output? ; @temporary_output end

    def initialize(options)
      @source_file_name = options[:source_file_name]
      @source_directories = options[:source_directories]
      @library_file_names = options[:library_file_names]
      @production = options[:production?]
      @test = options[:test?]
      @test_port = options[:test_port] || DEFAULT_TEST_PORT

      if options.include? :output_file_name
        @output_file_name = File.expand_path(options[:output_file_name])
      else
        @output_file_name = get_temporary_output_file_name
        @temporary_output = true
      end
    end

    def get_temporary_output_file_name
      "#{Dir.tmpdir}/asautotest-#{get_random_token}.swf"
    end

    def get_random_token
      "#{(Time.new.to_f * 1000).to_i}-#{(rand * 1_000_000).to_i}"
    end

    def compile_command
      if @compile_id
        %{compile #@compile_id}
      else
        build_string do |result|
          result << %{mxmlc}
          for source_directory in @source_directories do
            result << %{ -compiler.source-path=#{source_directory}}
          end
          for library in @library_file_names do
            result << %{ -compiler.library-path=#{library}}
          end
          result << %{ -output=#@output_file_name}
          result << %{ -static-link-runtime-shared-libraries}
          result << %{ -compiler.strict}
          result << %{ -debug} unless @production
          result << %{ #@source_file_name}
        end
      end
    end

    attr_accessor :compile_id
    attr_accessor :index
  end

  class Main
    include Logging

    def initialize(options)
      initialize_growl if options[:enable_growl?]
      @typing = options[:typing]
      @compilation_requests = options[:compilation_requests].
        map(&method(:make_compilation_request))
    end

    def initialize_growl
      begin
        require "growl"
        if Growl.installed?
          ASAutotest::growl_enabled = true
        else
          shout "You need to install the ‘growlnotify’ tool."
          say "Alternatively, use --no-growl to disable Growl notifications."
          exit -1
        end
      rescue LoadError
        hint "Hint: Install the ‘growl’ gem to enable Growl notifications."
      end
    end

    def make_compilation_request(options)
      options[:source_file_name] =
        File.expand_path(options[:source_file_name])
      implicit_source_directory =
        File.dirname(File.expand_path(options[:source_file_name])) + "/"
      options[:source_directories] = options[:source_directories].
        map { |directory_name| File.expand_path(directory_name) + "/" }
      options[:source_directories] << implicit_source_directory unless
        options[:source_directories].include? implicit_source_directory
      options[:library_file_names] = options[:library_file_names].
        map { |file_name| File.expand_path(file_name) }

      CompilationRequest.new(options)
    end

    def self.run(*arguments)
      new(*arguments).run
    end

    def run
      print_header
      start_compiler_shell
      build
      monitor_changes
    end

    def say_tabbed(left, right)
      say("#{left} ".ljust(21) + right)
    end

    def format_file_name(file_name)
      if file_name.start_with? ENV["HOME"]
        file_name.sub(ENV["HOME"], "~")
      else
        file_name
      end
    end

    def print_header
      new_logging_section

      for request in @compilation_requests
        say "\e[1m#{File.basename(request.source_file_name)}\e[0m"
        
        for source_directory in request.source_directories
          say_tabbed "  Source directory:",
            format_file_name(source_directory)
        end
        
        for library in request.library_file_names
          say_tabbed "  Library:", format_file_name(library)
        end

        if request.temporary_output? and not request.test?
          say "  Not saving output SWF (use --output=FILE.swf to specify)."
          say "  Not running as test (use --test to enable)."
        elsif not request.temporary_output?
          say_tabbed "  Output file:",
            "=> #{format_file_name(request.output_file_name)}"
        elsif request.test?
          say "  Running as test (using port #{request.test_port})."
        end

        say "  Compiling in production mode." if request.production?
      end

      say "Running in verbose mode." if Logging.verbose?

      if @typing == :dynamic
        say "Not warning about missing type declarations."
      end

      new_logging_section
    end

    def start_compiler_shell
      @compiler_shell = CompilerShell.new \
        :compilation_requests => @compilation_requests,
        :typing => @typing
      @compiler_shell.start
    end

    def monitor_changes
      user_wants_out = false

      Signal.trap("INT") do
        user_wants_out = true
        throw :asautotest_interrupt
      end
      
      until user_wants_out
        require "fssm"
        monitor = FSSM::Monitor.new

        for source_directory in source_directories
          monitor.path(source_directory, WATCH_GLOB) do |watch|
            watch.update { handle_change }
            watch.create { handle_change ; throw :asautotest_interrupt }
            watch.delete { handle_change ; throw :asautotest_interrupt }
          end
        end

        catch :asautotest_interrupt do
          begin
            monitor.run
          rescue
          end
        end
      end
    end

    def source_directories
      @compilation_requests.map(&:source_directories).flatten.uniq
    end

    def handle_change
      new_logging_section
      whisper "Change detected."
      build
    end

    def build
      compile

      for summary in @compilation.result.summaries
        if summary[:successful?]
          if compilation_successful? and summary[:request].test?
            run_test(summary[:request])
          end

          if summary[:request].temporary_output?
            delete_output_file(summary[:request].output_file_name)
          end
        end
      end

      whisper "Ready."
    end

    def compilation_successful?
      @compilation.result.successful?
    end

    def n_problems
      @compilation.result.n_problems
    end

    def n_problematic_files
      @compilation.result.n_problematic_files
    end

    def compile
      @compilation = CompilationRunner.new \
        @compiler_shell, :typing => @typing
      @compilation.run
    end

    def run_test(request)
      TestRunner.new(request.output_file_name, request.test_port).run
    end

    def delete_output_file(file_name)
      begin
        File.delete(file_name)
        whisper "Deleted binary."
      rescue Exception => exception
        shout "Failed to delete binary: #{exception.message}"
      end
    end
  end
end

def print_usage
  warn "\
usage: asautotest FILE.as [--test|-o FILE.swf] [-I SRCDIR|-l FILE.swc]...
       asautotest FILE.as [OPTION] [-- FILE.as [OPTION]]... [--- OPTIONS...]"
end

def new_compilation_request
  { :source_directories => [], :library_file_names => [] }
end

$compilation_requests = [new_compilation_request]
$typing = nil
$verbose = false
$enable_growl = RUBY_PLATFORM =~ /darwin/
$parsing_global_options = false

until ARGV.empty?
  request = $compilation_requests.last
  requests = $parsing_global_options ? $compilation_requests : [request]
  case argument = ARGV.shift
  when /^--output(?:=(\S+))?$/, "-o"
    if request.include? :output_file_name
      warn "asautotest: only one ‘--output’ allowed per source file"
      warn "asautotest: use ‘--’ to separate multiple source files"
      print_usage ; exit -1
    else
      request[:output_file_name] = ($1 || ARGV.shift)
    end
  when "--production"
    for request in requests
      request[:production?] = true
    end
  when "--test"
    if $parsing_global_options
      warn "asautotest: option ‘--test’ cannot be used globally"
      print_usage ; exit -1
    else
      request[:test?] = true
    end
  when "--test-port(?:=(\S+))?"
    value = ($1 || ARGV.shift).to_i
    for request in requests
      request[:test_port] = value
    end
  when /^--library(?:=(\S+))?$/, "-l"
    value = ($1 || ARGV.shift)
    for request in requests
      request[:library_file_names] << value
    end
  when /^--source=(?:=(\S+))?$/, "-I"
    value = ($1 || ARGV.shift)
    for request in requests
      request[:source_directories] << value
    end
  when /^--asspec-adapter-source$/
    value = File.join(ASAutotest::ROOT, "asspec", "src")
    for request in requests
      request[:source_directories] << value
    end
  when "--dynamic-typing"
    $typing = :dynamic
  when "--static-typing"
    $typing = :static
  when "--verbose"
    $verbose = true
  when "--no-growl"
    $enable_growl = false
  when "--"
    if request.include? :source_file_name
      $compilation_requests << new_compilation_request
    else
      warn "asautotest: no source file found before ‘--’"
      print_usage ; exit -1
    end
  when "---"
    if $parsing_global_options
      warn "asautotest: only one ‘---’ section allowed"
      print_usage ; exit -1
    else
      $parsing_global_options = true
    end
  when /^-/
    warn "asautotest: unrecognized argument: #{argument}"
    print_usage ; exit -1
  else
    if request.include? :source_file_name
      warn "asautotest: use ‘--’ to separate multiple source files"
      print_usage ; exit -1
    else
      request[:source_file_name] = argument
    end
  end
end

unless $compilation_requests.first[:source_file_name]
  warn "asautotest: please specify a source file to be compiled"
  print_usage ; exit -1
end

ASAutotest::Logging.verbose = $verbose

begin
  ASAutotest::Main.run \
    :compilation_requests => $compilation_requests,
    :typing => $typing,
    :enable_growl? => $enable_growl
rescue Interrupt
end

# Signal successful exit.
exit 200
