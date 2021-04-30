# -*- coding: utf-8 -*-
#
#--
# Copyright (C) 2009-2010 Thomas Leitner <t_leitner@gmx.at>
# Copyright (C) 2010-2014 Carsten Bormann <cabo@tzi.org>
#
# This file was derived from a part of the kramdown gem which is licensed under the MIT license.
# This derived work is also licensed under the MIT license, see LICENSE.
#++
#
require 'shellwords'

raise "sorry, 1.8 was last decade" unless RUBY_VERSION >= '1.9'

gem 'kramdown', '~> 2.3.0'
require 'kramdown'
my_span_elements =  %w{list figure xref eref iref cref spanx vspace}
Kramdown::Parser::Html::Constants::HTML_SPAN_ELEMENTS.concat my_span_elements

require 'rexml/parsers/baseparser'
require 'open3'                 # for math
require 'json'                  # for math
require 'rexml/document'        # for SVG and bibxml acrobatics

class Object
  def deep_clone
    Marshal.load(Marshal.dump(self))
  end
end

module Kramdown

  module Parser

    class RFC2629Kramdown < Kramdown

      def initialize(*doc)
        super
        @span_parsers.unshift(:xref)
        @span_parsers.unshift(:iref)
        @span_parsers.unshift(:span_pi)
        @block_parsers.unshift(:block_pi)
      end

      SECTIONS_RE = /Section(?:s (?:[\w.]+, )*[\w.]+,? and)? [\w.]+/

      def handle_bares(s, attr, format, href)
        sa = s.sub(/\A\S+\s/, '').split(/,? and /)
        sa[0..0] = *sa[0].split(', ')
        sz = sa.size
        if sz != 1         # we have to redo xml2rfc's work here
          @tree.children << Element.new(:text, "Sections ", {}) # XXX needs to split into Section/Appendix
          sa.each_with_index do |sec, i|
            attr1 = {"target" => href, "section" => sec, "sectionFormat" => "bare"}
            @tree.children << Element.new(:xref, nil, attr1)
            text = if i == 0 && sz == 2
                     " and "
                   elsif i == sz-1
                     " of "
                   elsif i == sz-2
                     ", and "
                   else
                     ", "
                   end
            @tree.children << Element.new(:text, text, {})
          end
          # attr stays unchanged, no section added
        else
          attr['section'] = sa[-1]
          attr['sectionFormat'] = format
        end
      end

      XREF_START = /\{\{(?:(?:\{(.*?)\}(?:\{(.*?)\})?)|(\X*?))((?:\}\})|\})/u

      # Introduce new {{target}} syntax for empty xrefs, which would
      # otherwise be an ugly ![!](target) or ![ ](target)
      # (I'd rather use [[target]], but that somehow clashes with links.)
      def parse_xref
        @src.pos += @src.matched_size
        unless @src[4] == "}}"
          warn "*** #{@src[0]}: unmatched braces #{@src[4].inspect}"
        end
        if contact_name = @src[1]
          attr = {'fullname' => contact_name}
          if ascii_name = @src[2]
            attr["asciiFullname"] = ascii_name
          end
          el = Element.new(:contact, nil, attr)
        else
          href = @src[3]
          attr = {}
          xtxt = nil
          if $options.v3
            (href, xtxt) = href.split('>', 2)
            # match Section ... of ...; set section, sectionFormat
            case href.gsub(/[\u00A0\s]+/, ' ') # may need nbsp and/or newlines
            when /\A(#{SECTIONS_RE}) of (.*)\z/
              href = $2
              handle_bares($1, attr, "of", href)
            when /\A(.*), (#{SECTIONS_RE})\z/
              href = $1
              handle_bares($2, attr, "comma", href)
            when /\A(.*) \((#{SECTIONS_RE})\)\z/
              href = $1
              handle_bares($2, attr, "parens", href)
            when /\A([\w.]+)<(.+)\z/
              href = $2
              attr['section'] = $1
              attr['sectionFormat'] = 'bare'
            when /\A<<(.+)\z/
              href = $1
              attr['format'] = 'title'
            when /\A<(.+)\z/
              href = $1
              attr['format'] = 'counter'
            end
          end
          href = href.gsub(/\A[0-9]/) { "_#{$&}" } # can't start an IDREF with a number
          attr['target'] = href
          el = Element.new(:xref, xtxt, attr)
        end
        @tree.children << el
      end
      define_parser(:xref, XREF_START, '\{\{')

      IREF_START = /\(\(\((.*?)\)\)\)/u

      # Introduce new (((target))) syntax for irefs
      def parse_iref
        @src.pos += @src.matched_size
        href = @src[1]
        el = Element.new(:iref, nil, {'target' => href}) # XXX
        @tree.children << el
      end
      define_parser(:iref, IREF_START, '\(\(\(')

      # HTML_INSTRUCTION_RE = /<\?(.*?)\?>/m    # still defined!

      # warn [:OPT_SPACE, OPT_SPACE, HTML_INSTRUCTION_RE].inspect

      PI_BLOCK_START = /^#{OPT_SPACE}<\?/u

      def parse_block_pi
        # warn [:BLOCK].inspect
        line = @src.current_line_number
        if (result = @src.scan(HTML_INSTRUCTION_RE))
          @tree.children << Element.new(:xml_pi, result, nil, category: :block, location: line)
          @src.scan(TRAILING_WHITESPACE)
          true
        else
          false
        end
      end
      define_parser(:block_pi, PI_BLOCK_START)

      PI_SPAN_START = /<\?/u

      def parse_span_pi
        # warn [:SPAN].inspect
        line = @src.current_line_number
        if (result = @src.scan(HTML_INSTRUCTION_RE))
          @tree.children << Element.new(:xml_pi, result, nil, category: :span, location: line)
        else
          add_text(@src.getch)
        end
      end
      define_parser(:span_pi, PI_SPAN_START, '<\?')

      # warn [:HERE, @@parsers.keys].inspect

    end
  end

  class Element

    # Not fixing studly element names postalLine and seriesInfo yet

    # occasionally regenerate the studly attribute name list via
    # script in data/studly.rb
    STUDLY_ATTR = %w(
    asciiAbbrev asciiFullname asciiInitials asciiName asciiSurname
    asciiValue blankLines derivedAnchor derivedContent derivedCounter
    derivedLink displayFormat docName expiresDate hangIndent hangText
    indexInclude iprExtract keepWithNext keepWithPrevious originalSrc
    prepTime quoteTitle quotedFrom removeInRFC sectionFormat seriesNo
    showOnFrontPage slugifiedName sortRefs submissionType symRefs tocDepth
    tocInclude
    )
    STUDLY_ATTR_MAP = Hash[STUDLY_ATTR.map {|s| [s.downcase, s]}]

    def rfc2629_fix
      if a = attr
        if anchor = a.delete('id')
          a['anchor'] = anchor
        end
        if anchor = a.delete('href')
          a['target'] = anchor
        end
        attr.keys.each do |k|
          if (d = k.gsub(/_(.|$)/) { $1.upcase }) != k or d = STUDLY_ATTR_MAP[k]
            a[d] = a.delete(k)
          end
        end
      end
    end
  end

  module Converter

    # Converts a Kramdown::Document to HTML.
    class Rfc2629 < Base

      # we use these to do XML stuff, too
      include ::Kramdown::Utils::Html

      def el_html_attributes(el)
        html_attributes(el.attr)
      end
      def el_html_attributes_with(el, defattr)
        html_attributes(defattr.merge(el.attr))
      end

      # :stopdoc:

      KRAMDOWN_PERSISTENT = ENV["KRAMDOWN_PERSISTENT"]
      KRAMDOWN_PERSISTENT_VERBOSE = /v/ === KRAMDOWN_PERSISTENT

      if KRAMDOWN_PERSISTENT
        begin
          require 'net/http/persistent'
          $http = Net::HTTP::Persistent.new name: 'kramdown-rfc'
        rescue Exception => e
          warn "** Can't set up persistent HTTP -- #{e}"
        end
      end

      # Defines the amount of indentation used when nesting XML tags.
      INDENTATION = 2

      # Initialize the XML converter with the given Kramdown document +doc+.
      def initialize(*doc)
        super
        @sec_level = 1
        @in_dt = 0
        @footnote_names_in_use = {}
      end

      def convert(el, indent = -INDENTATION, opts = {})
        if el.children[-1].type == :raw
          raw = convert1(el.children.pop, indent, opts)
        end
        "#{convert1(el, indent, opts)}#{end_sections(1, indent)}#{raw}"
      end

      def convert1(el, indent, opts = {})
        el.rfc2629_fix
        send("convert_#{el.type}", el, indent, opts)
      end

      def inner_a(el, indent, opts)
        indent += INDENTATION
        el.children.map do |inner_el|
          inner_el.rfc2629_fix
          send("convert_#{inner_el.type}", inner_el, indent, opts)
        end
      end

      def inner(el, indent, opts)
        inner_a(el, indent, opts).join('')
      end

      def convert_blank(el, indent, opts)
        "\n"
      end

      def convert_text(el, indent, opts)
        escape_html(el.value, :text)
      end

      def convert_p(el, indent, opts)
        if (el.children.size == 1 && el.children[0].type == :img) || opts[:unpacked]
          inner(el, indent, opts) # Part of the bad reference hack
        else
          "#{' '*indent}<t#{el_html_attributes(el)}>#{inner(el, indent, opts)}</t>\n"
        end
      end

      def saner_generate_id(value)
        generate_id(value).gsub(/-+/, '-')
      end

      SVG_COLORS = Hash.new {|h, k| k}
      <<COLORS.each_line {|l| k, v = l.chomp.split; SVG_COLORS[k] = v}
black	#000000
silver	#C0C0C0
gray	#808080
white	#FFFFFF
maroon	#800000
red	#FF0000
purple	#800080
fuchsia	#FF00FF
green	#008000
lime	#00FF00
olive	#808000
yellow	#FFFF00
navy	#000080
blue	#0000FF
teal	#008080
aqua	#00FFFF
COLORS

      def svg_munch_id(id)
        id.gsub(/[^-._A-Za-z0-9]/) {|x| "_%02X" % x.ord}
      end

      def self.hex_to_lin(h)
        h.to_i(16)**2.22        # approximating sRGB gamma
      end
      define_method :hex_to_lin, &method(:hex_to_lin)

      B_W_THRESHOLD = hex_to_lin("a4") # a little brighter than 1/2 0xFF -> white

      def svg_munch_color(c, fill)
        c = SVG_COLORS[c]
        case c
        when /\A#(..)(..)(..)\z/
          if hex_to_lin($1)*0.2126 + hex_to_lin($2)*0.7152 + hex_to_lin($3)*0.0722 >= B_W_THRESHOLD
            'white'
          else
            'black'
          end
        when 'none'
          'none' if fill        # delete for stroke
        else
          c
        end
      end

      def svg_clean(s)          # expensive, risky
        d = REXML::Document.new(s)
        REXML::XPath.each(d.root, "//*[@shape-rendering]") { |x| x.attributes["shape-rendering"] = nil }  #; warn x.inspect }
        REXML::XPath.each(d.root, "//*[@text-rendering]") { |x| x.attributes["text-rendering"] = nil }  #; warn x.inspect  }
        REXML::XPath.each(d.root, "//*[@stroke]") { |x| x.attributes["stroke"] = svg_munch_color(x.attributes["stroke"], false) }
        REXML::XPath.each(d.root, "//*[@fill]") { |x| x.attributes["fill"] = svg_munch_color(x.attributes["fill"], true) }
        REXML::XPath.each(d.root, "//*[@id]") { |x| x.attributes["id"] = svg_munch_id(x.attributes["id"]) }
##      REXML::XPath.each(d.root, "//rect") { |x| x.attributes["style"] = "fill:none;stroke:black;stroke-width:1" unless x.attributes["style"] }
        # Fix for mermaid:
        REXML::XPath.each(d.root, "//polygon") { |x| x.attributes["rx"] = nil; x.attributes["ry"] = nil }
        d.to_s
      rescue => detail
        warn "*** Can't clean SVG: #{detail}"
        d
      end

      def memoize(meth, *args)
        require 'digest'
        Dir.mkdir(REFCACHEDIR) unless Dir.exists?(REFCACHEDIR)
        kdrfc_version = Gem.loaded_specs["kramdown-rfc2629"].version.to_s.gsub('.', '_') rescue "UNKNOWN"
        fn = "#{REFCACHEDIR}/kdrfc-#{kdrfc_version}-#{meth}-#{Digest::SHA256.hexdigest(Marshal.dump(args))[0...40]}.cache"
        begin
          out = Marshal.load(File.binread(fn))
        rescue StandardError => e
          # warn e.inspect
          out = method(meth).call(*args)
          File.binwrite(fn, Marshal.dump(out))
        end
        out
      end

      def capture_croak(t, err)
        if err != ''
          err.lines do |l|
            warn "*** [#{t}:] #{l.chomp}"
          end
        end
      end

      def svg_tool_process(t, result)
        require 'tempfile'
        file = Tempfile.new("kramdown-rfc")
        file.write(result)
        file.close
        case t
        when "goat"
          result1, err, _s = Open3.capture3("goat #{file.path}", stdin_data: result);
        when "ditaa"        # XXX: This needs some form of option-setting
          result1, err, _s = Open3.capture3("ditaa #{file.path} --svg -o -", stdin_data: result);
        when "mscgen"
          result1, err, _s = Open3.capture3("mscgen -T svg -i #{file.path} -o -", stdin_data: result);
        when "mermaid"
          result1, err, _s = Open3.capture3("mmdc -i #{file.path}", stdin_data: result); #  -b transparent
          outpath = file.path + ".svg"
          result1 = File.read(outpath) rescue '' # don't die before providing error message
          File.unlink(outpath) rescue nil        # ditto
        when "plantuml", "plantuml-utxt"
          plantuml = "@startuml\n#{result}\n@enduml"
          result1, err, _s = Open3.capture3("plantuml -pipe -tsvg", stdin_data: plantuml);
          result, err1, _s = Open3.capture3("plantuml -pipe -tutxt", stdin_data: plantuml) if t == "plantuml-utxt"
          err << err1.to_s
        when "math"
          result1, err, _s = Open3.capture3("tex2svg --font STIX --speech=false #{Shellwords.escape(' ' << result)}");
          result, err1, _s = Open3.capture3("asciitex -f #{file.path}")
          err << err1
        end
        capture_croak(t, err)
        # warn ["goat:", result1.inspect]
        file.unlink
        result1 = svg_clean(result1) unless t == "goat"
        result1, err, _s = Open3.capture3("svgcheck -Xqa", stdin_data: result1);
        capture_croak("svgcheck", err)
        # warn ["svgcheck:", result1.inspect]
        if result1 == ''
          warn "*** could not create svg for #{result.inspect[0...20]}..."
          exit 65 # EX_DATAERR
        end
        [result, result1]       # text, svg
      end

      ARTWORK_TYPES = %w(ascii-art binary-art call-flow hex-dump svg)

      def convert_codeblock(el, indent, opts)
        # el.attr['anchor'] ||= saner_generate_id(el.value) -- no longer in 1.0.6
        result = el.value
        gi = el.attr.delete('gi')
        blockclass = el.attr.delete('class')
        if blockclass == 'language-tbreak'
          result = result.lines.map {|line| [line.chomp, 0]}
          spaceind = 0
          result.each_with_index {|pair, index|
            if pair[0] == ''
              result[spaceind][1] += 1
              pair[0] = nil unless index == spaceind
            else
              spaceind = index
            end
          }
          # $stderr.puts(result.inspect)
          result = result.map {|line, space|
            "<![CDATA[#{line.gsub(/^\s+/) {|s| "\u00A0" * s.size}}]]><vspace blankLines=\"#{space}\"/>" if line
          }.compact.join("\n")
          "#{' '*indent}<t>#{result}</t>\n"
        else
          artwork_attr = {}
          t = nil
          if blockclass
            classes = blockclass.split(' ')
            classes.each do |cl|
              if md = cl.match(/\Alanguage-(.*)/)
                t = artwork_attr["type"] = md[1] # XXX overwrite
              else
                $stderr.puts "*** Unimplemented codeblock class: #{cl}"
              end
            end
          end
          # compensate for XML2RFC idiosyncrasy by insisting on a blank line
          unless el.attr.delete('tight')
            result[0,0] = "\n" unless result[0,1] == "\n"
          end
          el.attr.each do |k, v|
            if md = k.match(/\A(?:artwork|sourcecode)-(.*)/)
              el.attr.delete(k)
              artwork_attr[md[1]] = v
            end
          end
          case t
          when "goat", "ditaa", "mscgen", "plantuml", "plantuml-utxt", "mermaid", "math"
            if gi
              warn "*** Can't set GI #{gi} for composite SVG artset"
            end
            result, result1 = memoize(:svg_tool_process, t, result)
            "#{' '*indent}<figure#{el_html_attributes(el)}><artset><artwork #{html_attributes(artwork_attr.merge("type"=> "svg"))}>#{result1.sub(/.*?<svg/m, "<svg")}</artwork><artwork #{html_attributes(artwork_attr.merge("type"=> "ascii-art"))}><![CDATA[#{result}#{result =~ /\n\Z/ ? '' : "\n"}]]></artwork></artset></figure>\n"
          else
            gi ||= (
              if !$options.v3 || !t || ARTWORK_TYPES.include?(t) || artwork_attr["align"]
                "artwork"
              else
                "sourcecode"
              end
            )
            "#{' '*indent}<figure#{el_html_attributes(el)}><#{gi}#{html_attributes(artwork_attr)}><![CDATA[#{result}#{result =~ /\n\Z/ ? '' : "\n"}]]></#{gi}></figure>\n"
          end
        end
      end

      def convert_blockquote(el, indent, opts)
        text = inner(el, indent, opts)
        text = "<t></t>" unless text =~ /</ # empty block quote
        "#{' '*indent}<t><list style='empty'#{el_html_attributes(el)}>\n#{text}#{' '*indent}</list></t>\n"
      end

      def end_sections(to_level, indent)
        if indent < 0
          indent = 0
        end
        if @sec_level >= to_level
          delta = (@sec_level - to_level)
          @sec_level = to_level
          "#{' '*indent}</section>\n" * delta
        else
          $stderr.puts "Incorrect section nesting: Need to start with 1"
        end
      end

      def clean_pcdata(parts)    # hack, will become unnecessary with XML2RFCv3
        clean = ''
        irefs = ''
        # warn "clean_parts: #{parts.inspect}"
        parts.each do |p|
          md = p.match(%r{([^<]*)(.*)})
          clean << md[1]
          irefs << md[2]        # breaks for spanx... don't emphasize in headings!
        end
        [clean, irefs]
      end

      def convert_header(el, indent, opts)
        # todo: handle appendix tags
        el = el.deep_clone
        options = @doc ? @doc.options : @options # XXX: 0.11 vs. 0.12
        if options[:auto_ids] && !el.attr['anchor']
          el.attr['anchor'] = saner_generate_id(el.options[:raw_text])
        end
        if $options.v3
          if sl = el.attr.delete('slugifiedName') # could do general name- play
            attrstring = html_attributes({'slugifiedName' => sl})
          end
          irefs = "<name#{attrstring}>#{inner(el, indent, opts)}</name>" #
        else
        clean, irefs = clean_pcdata(inner_a(el, indent, opts))
        el.attr['title'] = clean
        end
        "#{end_sections(el.options[:level], indent)}#{' '*indent}<section#{@sec_level += 1; el_html_attributes(el)}>#{irefs}\n"
      end

      def convert_hr(el, indent, opts) # misuse for page break
        "#{' '*indent}<t><vspace blankLines='999' /></t>\n"
      end

      STYLES = {ul: 'symbols', ol: 'numbers', dl: 'hanging'}

      def convert_ul(el, indent, opts)
        opts = opts.merge(vspace: el.attr.delete('vspace'))
        attrstring = el_html_attributes_with(el, {"style" => STYLES[el.type]})
        if opts[:unpacked]
          "#{' '*indent}<list#{attrstring}>\n#{inner(el, indent, opts)}#{' '*indent}</list>\n"
          else
          "#{' '*indent}<t><list#{attrstring}>\n#{inner(el, indent, opts)}#{' '*indent}</list></t>\n"
        end
      end
      alias :convert_ol :convert_ul

      def convert_dl(el, indent, opts)
        if $options.v3
          if hangindent = el.attr.delete('hangIndent')
            el.attr['indent'] ||= hangindent # new attribute name wins
          end
          vspace = el.attr.delete('vspace')
          if vspace && !el.attr['newline']
            el.attr['newline'] = 'true'
          end
          "#{' '*indent}<dl#{el_html_attributes(el)}>\n#{inner(el, indent, opts.dup)}#{' '*indent}</dl>\n"
        else
          convert_ul(el, indent, opts)
        end
      end

      def convert_li(el, indent, opts)
        res_a = inner_a(el, indent, opts)
        if el.children.empty? || el.children.first.options[:category] == :span
          res = res_a.join('')
        else                    # merge multiple <t> elements
          res = res_a.select { |x|
            x.strip != ''
          }.map { |x|
            x.sub(/\A\s*<t>(.*)<\/t>\s*\Z/m) { $1}
          }.join("#{' '*indent}<vspace blankLines='1'/>\n").gsub(%r{(</list>)\s*<vspace blankLines='1'/>}) { $1 }.gsub(%r{<vspace blankLines='1'/>\s*(<list)}) { $1 }
        end
        "#{' '*indent}<t#{el_html_attributes(el)}>#{res}#{(res =~ /\n\Z/ ? ' '*indent : '')}</t>\n"
      end

      def convert_dd(el, indent, opts)
        if $options.v3
          out = ''
          if !opts[:haddt]
            out ="#{' '*indent}<dt/>\n" # you can't make this one up
          end
          opts[:haddt] = false
          out << "#{' '*indent}<dd#{el_html_attributes(el)}>\n#{inner(el, indent, opts)}#{' '*indent}</dd>\n"
        else
        output = ' '*indent
        if @in_dt == 1
          @in_dt = 0
        else
          output << "<t#{el_html_attributes(el)}>"
        end
        res = inner(el, indent+INDENTATION, opts.merge(unpacked: true))
#        if el.children.empty? || el.children.first.options[:category] != :block
          output << res << (res =~ /\n\Z/ ? ' '*indent : '')
#        else                    FIXME: The latter case is needed for more complex cases
#          output << "\n" << res << ' '*indent
#        end
        output << "</t>\n"
        end
      end

      def convert_dt(el, indent, opts) # SERIOUSLY BAD HACK:
        if $options.v3
          out = ''
          if opts[:haddt]
            out ="#{' '*indent}<dd><t/></dd>\n" # you can't make this one up
          end
          opts[:haddt] = true
          out << "#{' '*indent}<dt#{el_html_attributes(el)}>\n#{inner(el, indent, opts)}#{' '*indent}</dt>\n"
        else
        close = "#{' '*indent}</t>\n" * @in_dt
        @in_dt = 1
        vspace = opts[:vspace]
        vspaceel = "<vspace blankLines='#{vspace}'/>" if vspace
        ht = escape_html(inner(el, indent, opts), :attribute) # XXX this may leave gunk
        "#{close}#{' '*indent}<t#{el_html_attributes(el)} hangText=\"#{ht}\">#{vspaceel}\n"
        end
      end

      HTML_TAGS_WITH_BODY=['div', 'script']

      def convert_html_element(el, indent, opts)
        res = inner(el, indent, opts)
        if el.options[:category] == :span
          "<#{el.value}#{el_html_attributes(el)}" << (!res.empty? ? ">#{res}</#{el.value}>" : " />")
        else
          output = ''
          output << ' '*indent if !el.options[:parent_is_raw]
          output << "<#{el.value}#{el_html_attributes(el)}"
          if !res.empty? && el.options[:parse_type] != :block
            output << ">#{res}</#{el.value}>"
          elsif !res.empty?
            output << ">\n#{res}"  << ' '*indent << "</#{el.value}>"
          elsif HTML_TAGS_WITH_BODY.include?(el.value)
            output << "></#{el.value}>"
          else
            output << " />"
          end
          output << "\n" if el.options[:outer_element] || !el.options[:parent_is_raw]
          output
        end
      end

      def convert_xml_comment(el, indent, opts)
        if el.options[:category] == :block && !el.options[:parent_is_raw]
          ' '*indent + el.value + "\n"
        else
          el.value
        end
      end
      alias :convert_xml_pi :convert_xml_comment
      alias :convert_html_doctype :convert_xml_comment

      ALIGNMENTS = { default: :left, left: :left, right: :right, center: :center}
      COLS_ALIGN = { "l" => :left, "c" => :center, "r" => :right}

      def convert_table(el, indent, opts) # This only works for tables with headers
        alignment = el.options[:alignment].map { |al| ALIGNMENTS[al]}
        cols = (el.attr.delete("cols") || "").split(' ')
        "#{' '*indent}<texttable#{el_html_attributes(el)}>\n#{inner(el, indent, opts.merge(table_alignment: alignment, table_cols: cols))}#{' '*indent}</texttable>\n"
      end

      def convert_thead(el, indent, opts)
        inner(el, indent, opts)
      end
      alias :convert_tbody :convert_thead
      alias :convert_tfoot :convert_thead
      alias :convert_tr  :convert_thead

      def convert_td(el, indent, opts)
        if alignment = opts[:table_alignment]
          alignment = alignment.shift
          if cols = opts[:table_cols].shift
            md = cols.match(/(\d*(|em|[%*]))([lrc])/)
            if md[1].to_i != 0
              widthval = md[1]
              widthval << "em" if md[2].empty?
              widthopt = "width='#{widthval}' "
            end
            alignment = COLS_ALIGN[md[3]] || :left
          end
        end
        if alignment
          res, irefs = clean_pcdata(inner_a(el, indent, opts))
          warn "*** lost markup #{irefs} in table heading" unless irefs.empty?
          "#{' '*indent}<ttcol #{widthopt}align='#{alignment}'#{el_html_attributes(el)}>#{res.empty? ? "&#160;" : res}</ttcol>\n" # XXX need clean_pcdata
        else
          res = inner(el, indent, opts)
          "#{' '*indent}<c#{el_html_attributes(el)}>#{res.empty? ? "&#160;" : res}</c>\n"
        end
      end
      alias :convert_th :convert_td

      def convert_comment(el, indent, opts)
## Don't actually output all those comments into the XML:
#        if el.options[:category] == :block
#          "#{' '*indent}<!-- #{el.value} -->\n"
#        else
#          "<!-- #{el.value} -->"
#        end
      end

      def convert_br(el, indent, opts)
        if $options.v3
          "<br />"
        else
          "<vspace />"
        end
      end

      def convert_a(el, indent, opts)
        gi = el.attr.delete('gi')
        res = inner(el, indent, opts)
        target = el.attr['target']
        if target[0] == "#"     # handle [](#foo) as xref as in RFC 7328
          el.attr['target'] = target = target[1..-1]
          if target.downcase == res.downcase
            res = ''            # get rid of raw anchors leaking through
          end
          gi ||= "xref"
        else
          gi ||= "eref"
        end
        "<#{gi}#{el_html_attributes(el)}>#{res}</#{gi}>"
      end

      def convert_xref(el, indent, opts)
        gi = el.attr.delete('gi')
        target = el.attr['target']
        if target[0] == "&"
          "#{target};"
        else
          if target =~ %r{\A\w+:(?://|.*@)}
            gi ||= "eref"
          else
            gi ||= "xref"
          end
          if el.value
            tail = ">#{escape_html(el.value, :text)}</#{gi}>"
          else
            tail = "/>"
          end
          "<#{gi}#{el_html_attributes(el)}#{tail}"
        end
      end

      def convert_contact(el, indent, opts)
        "<contact#{el_html_attributes(el)}/>"
      end

      REFCACHEDIR = ENV["KRAMDOWN_REFCACHEDIR"] || ".refcache"

      # warn "*** REFCACHEDIR #{REFCACHEDIR}"

      KRAMDOWN_OFFLINE = ENV["KRAMDOWN_OFFLINE"]
      KRAMDOWN_REFCACHE_REFETCH = ENV["KRAMDOWN_REFCACHE_REFETCH"]

      def get_and_write_resource(url, fn)
        options = {}
        if ENV["KRAMDOWN_DONT_VERIFY_HTTPS"]
          options[:ssl_verify_mode] = OpenSSL::SSL::VERIFY_NONE
        end             # workaround for OpenSSL on Windows...
        # URI.open(url, **options) do |uf|          # not portable to older versions
        OpenURI.open_uri(url, **options) do |uf|
          s = uf.read
          if uf.status[0] != "200"
            warn "*** Status code #{status} while fetching #{url}"
          else
            File.write(fn, s)
          end
        end
      end

      def get_and_write_resource_persistently(url, fn)
        t1 = Time.now
        response = $http.request(URI(url))
        if response.code != "200"
          raise "Status code #{response.code} while fetching #{url}"
        else
          File.write(fn, response.body)
        end
        t2 = Time.now
        warn "(#{"%.3f" % (t2 - t1)} s)" if KRAMDOWN_PERSISTENT_VERBOSE
      end

      # this is now slightly dangerous as multiple urls could map to the same cachefile
      def get_and_cache_resource(url, cachefile, tvalid = 7200, tn = Time.now)
        fn = "#{REFCACHEDIR}/#{cachefile}"
        Dir.mkdir(REFCACHEDIR) unless Dir.exists?(REFCACHEDIR)
        f = File.stat(fn) rescue nil unless KRAMDOWN_REFCACHE_REFETCH
        if !KRAMDOWN_OFFLINE && (!f || tn - f.mtime >= tvalid)
          if f
            message = "renewing (stale by #{"%.1f" % ((tn-f.mtime)/86400)} days)"
            fetch_timeout = 10 # seconds, give up quickly if just renewing
          else
            message = "fetching"
            fetch_timeout = 60 # seconds; long timeout needed for Travis
          end
          $stderr.puts "#{fn}: #{message} from #{url}"
          if ENV["HAVE_WGET"]
            `cd #{REFCACHEDIR}; wget -t 3 -T #{fetch_timeout} -Nnv "#{url}"` # ignore errors if offline (hack)
            begin
              File.utime nil, nil, fn
            rescue Errno::ENOENT
              warn "Can't fetch #{url} -- is wget in path?"
            end
          else
            require 'open-uri'
            require 'socket'
            require 'openssl'
            require 'timeout'
            begin
              Timeout::timeout(fetch_timeout) do
                if $http
                  begin         # belt and suspenders
                    get_and_write_resource_persistently(url, fn)
                  rescue Exception => e
                    warn "*** Can't get with persistent HTTP: #{e}"
                    get_and_write_resource(url, fn)
                  end
                else
                  get_and_write_resource(url, fn)
                end
              end
            rescue OpenURI::HTTPError, Errno::EHOSTUNREACH, Errno::ECONNREFUSED,
                   SocketError, Timeout::Error => e
              warn "*** #{e} while fetching #{url}"
            end
          end
        end
        begin
          File.read(fn) # this blows up if no cache available after fetch attempt
        rescue Errno::ENOENT => e
          warn "*** #{e} for #{fn}"
        end
      end

      # [subdirectory name, cache ttl in seconds, does it provide for ?anchor=]
      XML_RESOURCE_ORG_MAP = {
        "RFC" => ["bibxml", 86400*7, false,
                  ->(fn, n){ "https://www.rfc-editor.org/refs/bibxml/#{fn}"}
                 ],
        "I-D" => ["bibxml3", false, false,
                  ->(fn, n){ "https://datatracker.ietf.org/doc/bibxml3/draft-#{n.sub(/\Adraft-/, '')}/xml" }
                 ],
        "W3C" => "bibxml4",
        "3GPP" => "bibxml5",
        "ANSI" => "bibxml2",
        "CCITT" => "bibxml2",
        "FIPS" => "bibxml2",
        # "IANA" => "bibxml2",   overtaken by bibxml8
        "IEEE" => "bibxml6",    # copied over to bibxml6 2019-02-27
        "ISO" => "bibxml2",
        "ITU" => "bibxml2",
        "NIST" => "bibxml2",
        "OASIS" => "bibxml2",
        "PKCS" => "bibxml2",
        "DOI" => ["bibxml7", 86400, true], # 24 h cache at source anyway
        "IANA" => ["bibxml8", 86400, true], # ditto
      }

      # XML_RESOURCE_ORG_HOST = ENV["XML_RESOURCE_ORG_HOST"] || "xml.resource.org"
      XML_RESOURCE_ORG_HOST = ENV["XML_RESOURCE_ORG_HOST"] || "xml2rfc.tools.ietf.org"
      XML_RESOURCE_ORG_PREFIX = ENV["XML_RESOURCE_ORG_PREFIX"] ||
                                "https://#{XML_RESOURCE_ORG_HOST}/public/rfc"
      KRAMDOWN_USE_TOOLS_SERVER = ENV["KRAMDOWN_USE_TOOLS_SERVER"]

      KRAMDOWN_REFCACHETTL = (e = ENV["KRAMDOWN_REFCACHETTL"]) ? e.to_i : 3600

      KRAMDOWN_NO_TARGETS = ENV['KRAMDOWN_NO_TARGETS']

      def convert_img(el, indent, opts) # misuse the tag!
        if a = el.attr
          alt = a.delete('alt').strip
          alt = '' if alt == '!' # work around re-wrap uglyness
          if src = a.delete('src')
            a['target'] = src
          end
        end
        if alt == ":include:"   # Really bad misuse of tag...
          anchor = el.attr.delete('anchor') || (
            # not yet
            warn "*** missing anchor for '#{src}'"
            src
          )
          anchor.sub!(/\A[0-9]/) { "_#{$&}" } # can't start an ID with a number
          anchor.gsub!('/', '_')              # should take out all illegals
          to_insert = ""
          src.scan(/(W3C|3GPP|[A-Z-]+)[.]?([A-Za-z_0-9.\/\+-]+)/) do |t, n|
            fn = "reference.#{t}.#{n}.xml"
            sub, ttl, _can_anchor, altproc = XML_RESOURCE_ORG_MAP[t]
            ttl ||= KRAMDOWN_REFCACHETTL  # everything but RFCs might change a lot
            puts "*** Huh: #{fn}" unless sub
            if altproc && !KRAMDOWN_USE_TOOLS_SERVER
              url = altproc.call(fn, n)
            else
              url = "#{XML_RESOURCE_ORG_PREFIX}/#{sub}/#{fn}"
            end
            # if can_anchor # create anchor server-side for stand_alone: false
            #   url << "?anchor=#{anchor}"
            #   fn[/.xml$/] = "--anchor=#{anchor}.xml"
            # end
            to_insert = get_and_cache_resource(url, fn.gsub('/', '_'), ttl)
            to_insert.scrub! rescue nil # only do this for Ruby >= 2.1

            begin
              d = REXML::Document.new(to_insert)
              d.xml_decl.nowrite
              d.root.attributes["anchor"] = anchor
              if t == "RFC" or t == "I-D"
                if KRAMDOWN_NO_TARGETS
                  d.root.attributes["target"] = nil
                  REXML::XPath.each(d.root, "/reference/format") { |x|
                    d.root.delete_element(x)
                  }
                else
                  REXML::XPath.each(d.root, "/reference/format") { |x|
                    x.attributes["target"].sub!(%r{https?://www.ietf.org/internet-drafts/},
                                                %{https://www.ietf.org/archive/id/}) if t == "I-D"
                  }
                end
              end
              to_insert = d.to_s
            rescue Exception => e
              warn "** Can't manipulate reference XML: #{e}"
              broken = true
              to_insert = nil
            end
            # this may be a bit controversial: Don't break the build if reference is broken
            if KRAMDOWN_OFFLINE || broken
              unless to_insert
                to_insert = "<reference anchor='#{anchor}'> <front> <title>*** BROKEN REFERENCE ***</title> <author> <organization/> </author> <date/> </front> </reference>"
                warn "*** KRAMDOWN_OFFLINE: Inserting broken reference for #{fn}"
              end
            else
              exit 66 unless to_insert # EX_NOINPUT
            end
          end
          to_insert
        else
          "<xref#{el_html_attributes(el)}>#{alt}</xref>"
        end
      end

      def convert_codespan(el, indent, opts)
        attrstring = el_html_attributes_with(el, {"style" => 'verb'})
        "<spanx#{attrstring}>#{escape_html(el.value)}</spanx>"
      end

      def convert_footnote(el, indent, opts) # XXX: footnotes into crefs???
        # this would be more like xml2rfc v3:
        # "\n#{' '*indent}<cref>\n#{inner(el.value, indent, opts).rstrip}\n#{' '*indent}</cref>"
        content = inner(el.value, indent, opts).strip
        content = escape_html(content.sub(/\A<t>(.*)<\/t>\z/m) {$1}, :text) # text only...
        name = el.options[:name].sub(/\A[0-9]/) {"_" << $&}
        while @footnote_names_in_use[name] do
          if name =~ /:\d+\z/
            name.succ!
          else
            name << ":1"
          end
        end
        @footnote_names_in_use[name] = true
        attrstring = el_html_attributes_with(el, {"anchor" => name})
        "\n#{' '*indent}<cref#{attrstring}>#{content}</cref>"
      end

      def convert_raw(el, indent, opts)
        end_sections(1, indent) +
        el.value + (el.options[:category] == :block ? "\n" : '')
      end

      EMPH = { em: "emph", strong: "strong"}

      def convert_em(el, indent, opts)
        if $options.v3
          gi = el.type
          "<#{gi}#{el_html_attributes(el)}>#{inner(el, indent, opts)}</#{gi}>"
        else
        attrstring = el_html_attributes_with(el, {"style" => EMPH[el.type]})
        span, irefs = clean_pcdata(inner_a(el, indent, opts))
        "<spanx#{attrstring}>#{span}</spanx>#{irefs}"
        end
      end
      alias :convert_strong :convert_em

      def convert_entity(el, indent, opts)
        entity_to_str(el.value)
      end

      TYPOGRAPHIC_SYMS = {
        :mdash => [::Kramdown::Utils::Entities.entity('mdash')],
        :ndash => [::Kramdown::Utils::Entities.entity('ndash')],
        :hellip => [::Kramdown::Utils::Entities.entity('hellip')],
        :laquo_space => [::Kramdown::Utils::Entities.entity('laquo'), ::Kramdown::Utils::Entities.entity('nbsp')],
        :raquo_space => [::Kramdown::Utils::Entities.entity('nbsp'), ::Kramdown::Utils::Entities.entity('raquo')],
        :laquo => [::Kramdown::Utils::Entities.entity('laquo')],
        :raquo => [::Kramdown::Utils::Entities.entity('raquo')]
      }
      def convert_typographic_sym(el, indent, opts)
        if (result = @options[:typographic_symbols][el.value])
          escape_html(result, :text)
        else
          TYPOGRAPHIC_SYMS[el.value].map {|e| entity_to_str(e) }.join('')
        end
      end

      def convert_smart_quote(el, indent, opts)
        entity_to_str(smart_quote_entity(el))
      end

      MATH_LATEX_FILENAME = File.expand_path '../../data/math.json', __FILE__
      MATH_LATEX = JSON.parse(File.read(MATH_LATEX_FILENAME, encoding: Encoding::UTF_8))
      MATH_REPLACEMENTS = MATH_LATEX["replacements"]
      MATH_COMBININGMARKS = MATH_LATEX["combiningmarks"]

      def munge_latex(s)
        MATH_REPLACEMENTS.each do |o, n|
          s.gsub!(o, n)
        end
        MATH_COMBININGMARKS.each do |m, n|
          re = /\\#{m[1..-1]}\{(\X)\}/
          s.gsub!(re) { "#$1#{n}" }
        end
        s
      end
      # XXX: This is missing sup/sub support, which needs to be added

      def convert_math(el, indent, opts) # XXX: This is wrong
        el = el.deep_clone
        if el.options[:category] == :block
          el.attr['artwork-type'] ||= ''
          el.attr['artwork-type'] += (el.attr['artwork-type'].empty? ? '' : ' ') + 'math'
          artwork_attr = {}
          el.attr.each do |k, v|
            if md = k.match(/\Aartwork-(.*)/)
              el.attr.delete(k)
              artwork_attr[md[1]] = v
            end
          end
          result, err, _s = Open3.capture3("tex2mail -noindent -ragged -by_par -linelength=69", stdin_data: el.value);
          # warn "*** tex2mail not in path?" unless s.success? -- doesn't have useful status
          capture_croak("tex2mail", err)
          "#{' '*indent}<figure#{el_html_attributes(el)}><artwork#{html_attributes(artwork_attr)}><![CDATA[#{result}#{result =~ /\n\Z/ ? '' : "\n"}]]></artwork></figure>\n"

        else
          type = 'spanx'
          if $options.v3
            type = 'contact'
            result = munge_latex(el.value)
            attrstring = el_html_attributes_with(el, {"fullname" => result.chomp, "asciiFullname" => ''})
          else
            warn "*** no support for inline math in XML2RFCv2"
            type = 'spanx'
            attrstring = el_html_attributes_with(el, {"style" => 'verb'})
            content = escape_html(el.value, :text)
          end
          "<#{type}#{attrstring}>#{content}</#{type}>"
        end
      end

      ITEM_RE = '\s*(?:"([^"]*)"|([^,]*?))\s*'
      IREF_RE = %r{\A(!\s*)?#{ITEM_RE}(?:,#{ITEM_RE})?\z}

      def iref_attr(s)
        md = s.match(IREF_RE)
        attr = {
          item: md[2] || md[3],
          subitem: md[4] || md[5],
          primary: md[1] && 'true',
        }
        "<iref#{html_attributes(attr)}/>"
      end

      def convert_iref(el, indent, opts)
        iref_attr(el.attr['target'])
      end

      def convert_abbreviation(el, indent, opts) # XXX: This is wrong
        title = @root.options[:abbrev_defs][el.value]
        title = nil if title.empty?
        value = el.value
        if item = title
          if item == "<bcp14>" && $options.v3
            return "<bcp14>#{el.value}</bcp14>"
          end
          m = title.scan(Parser::RFC2629Kramdown::IREF_START)
          if m.empty?
            subitem = value
          else
            iref = m.map{|a,| iref_attr(a)}.join('')
          end
        else
          item = value
        end
        iref ||= "<iref#{html_attributes(item: item, subitem: subitem)}/>"
        "#{el.value}#{iref}"
      end

      def convert_root(el, indent, opts)
        result = inner(el, indent, opts)
      end

    end

  end
end
