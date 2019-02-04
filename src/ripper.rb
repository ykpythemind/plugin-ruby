#!/usr/bin/env ruby

require 'json'
require 'ripper'

class RipperJS < Ripper::SexpBuilder
  attr_reader :start_comments

  def initialize(*args)
    super

    @start_comments = []
    @begin_comments = []

    @end_comment = nil
    @embdoc = nil

    @stack = []
  end

  def parse
    super.tap do |sexp|
      next if start_comments.empty?

      node = sexp[:body][0]
      node = node[:body][0] until node[:body][0][:type] != :stmts_add

      start_comments.each do |comment|
        node[:body][0] = {
          type: :stmts_add,
          body: [node[:body][0], comment],
          lineno: comment[:lineno]
        }
        node = node[:body][0]
      end
    end
  end

  private

  SCANNER_EVENTS.each do |event|
    module_eval(<<-End, __FILE__, __LINE__ + 1)
      def on_#{event}(token)
        { type: :@#{event}, body: token, lineno: lineno }
      end
    End
  end

  events = private_instance_methods(false).grep(/\Aon_/) { $'.to_sym }
  (PARSER_EVENTS - events).each do |event|
    module_eval(<<-End, __FILE__, __LINE__ + 1)
      def on_#{event}(*args)
        build_sexp(:#{event}, args)
      end
    End
  end

  def build_sexp(type, body)
    sexp = { type: type, body: body, lineno: lineno }

    if @begin_comments.any? && type == :stmts_new
      while @begin_comments.any?
        begin_comment = @begin_comments.shift

        sexp = {
          type: :stmts_add,
          body: [sexp, begin_comment],
          lineno: begin_comment[:lineno]
        }
      end
    end

    if @end_comment
      sexp[:comment] = @end_comment
      @end_comment = nil
    end

    @stack << sexp
    sexp
  end

  def on_comment(comment)
    sexp = { type: :@comment, body: comment.chomp, lineno: lineno }
    lex_state = RipperJS.lex_state_name(state)

    if lex_state == 'EXPR_BEG' # on it's own line
      handle_comment(sexp)
    elsif lex_state == 'EXPR_END' && @stack[-1]
      @stack[-1].merge!(comment: sexp.merge!(type: :comment))
    else
      @end_comment = sexp.merge!(type: :comment)
    end
  end

  def on_embdoc_beg(comment)
    @embdoc = { type: :@embdoc, body: comment, lineno: lineno }
  end

  def on_embdoc(comment)
    @embdoc[:body] << comment
  end

  def on_embdoc_end(comment)
    @embdoc[:body] << comment.chomp
    handle_comment(@embdoc)
  end

  def on_magic_comment(*); end

  def handle_comment(comment)
    if !@stack[-1] # the very first statement
      @start_comments.unshift(comment)
    elsif @stack[-1][:type] != :stmts_add # the first statement of the block
      @begin_comments << comment
    elsif @stack[-2][:type] == :void_stmt # the only statement of the block
      @stack[-1][:body][1] = comment
    else # in the middle of a list of statements
      @stack[-1].merge!(
        body: [
          {
            type: :stmts_add,
            body: [@stack[-1][:body][0], @stack[-1][:body][1]],
            lineno: @stack[-1][:body][1][:lineno]
          },
          comment
        ],
        lineno: lineno
      )
    end
  end
end

if $0 == __FILE__
  response = RipperJS.new(ARGV[0]).parse

  if response.nil?
    STDERR.puts 'Invalid ruby'
    exit 1
  end

  puts JSON.dump(response)
end
