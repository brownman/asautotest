# -*- coding: utf-8 -*-
# compiler-shell.rb --- wrapper around the fcsh executable
# Copyright (C) 2010  Go Interactive

# This file is part of asautotest.

# asautotest is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.

# asautotest is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.

# You should have received a copy of the GNU General Public License
# along with asautotest.  If not, see <http://www.gnu.org/licenses/>.

module ASAutotest
  class CompilerShell
    PROMPT = "\n(fcsh) "
    class PromptNotFound < Exception ; end

    include Logging

    attr_reader :output_file_name
    attr_reader :source_directories

    def initialize(options)
      @source_directories = options[:source_directories]
      @library_path = options[:library_path]
      @input_file_name = options[:input_file_name]
      @output_file_name = options[:output_file_name]
    end

    def start
      say "Starting compiler shell" do
        @process = IO.popen("#{FCSH} 2>&1", "r+")
        read_until_prompt
      end
    rescue PromptNotFound => error
      shout "Could not find FCSH prompt:"
      for line in error.message.lines do
        barf line.chomp
      end
      if error.message.include? "command not found"
        shout "Please make sure that fcsh is in your PATH."
        shout "Alternatively, set the ‘FCSH’ environment variable."
      end
      exit -1
    end

    def read_until_prompt
      result = ""
      until result.include? PROMPT
        result << @process.readpartial(100) 
      end
      result.lines.entries[0 .. -2]
    rescue EOFError
      raise PromptNotFound, result
    end

    def run_compilation
      if @compilation_initialized
        run_saved_compilation
      else
        run_first_compilation
      end
    end

    def run_first_compilation
      @process.puts(compile_command)
      @compilation_initialized = true
      read_until_prompt
    end

    def run_saved_compilation
      @process.puts("compile 1")
      read_until_prompt
    end

    def compile_command
      build_string do |result|
        result << %{mxmlc}
        for source_directory in @source_directories do
          result << %{ -compiler.source-path=#{source_directory}}
        end
        for library in @library_path do
          result << %{ -compiler.library-path=#{library}}
        end
        result << %{ -output=#@output_file_name}
        result << %{ -static-link-runtime-shared-libraries}
        result << %{ #@input_file_name}
      end
    end
  end
end
