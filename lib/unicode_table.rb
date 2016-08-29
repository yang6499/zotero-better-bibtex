#!/usr/bin/env ruby

require 'nokogiri'
require 'ostruct'
require 'open-uri'
require 'yaml'
require 'json'
require 'regexp_parser'
require 'progressbar'
require 'sqlite3'

class UnicodeConverter
  @@lowmask = ('1' * 10).to_i(2)
  @@cache = 'resource/translators/unicode.mapping'

  def self.cache
    return @@cache
  end

  def char(charcode)
    return "'\\\\'" if charcode == '\\'.ord
    return "'".inspect if charcode == "'".ord

    return "'#{charcode.chr}'" if charcode >= 0x20 && charcode <= 0x7E

    return "'\\u#{charcode.to_s(16).upcase.rjust(4, '0')}'" if charcode < 0x10000

    codepoint = charcode - 0x10000
    codepoint = [(codepoint >> 10) + 0xD800, (@@lowmask & codepoint) + 0xDC00].collect{|n| n.to_s(16).upcase.rjust(4, '0')}
    return "'" + codepoint.collect{|cp| "\\u" + cp}.join('') + "'"
  end

  def save(target)
    target = File.expand_path(target)
    open((target), 'w'){|cs|
      cs.puts "# Generated by #{File.basename(__FILE__)}. Edits will be overwritten"
      cs.puts "LaTeX = {} unless LaTeX"
      cs.puts "LaTeX.toLaTeX = { unicode: {}, ascii: {}, embrace: {} }"

      %w{unicode ascii}.each{|encoding|
        mappings = {'text' => {}, 'math' => {}}
        # an ascii character that needs translation? Probably a TeX special character, so also do when exporting to
        # unicode
        @chars.execute("SELECT charcode, latex, mode, description FROM mapping WHERE preference = 0 AND unicode_to_latex IN ('true', ?) ORDER BY charcode", [ encoding ]){|mapping|
          charcode, latex, mode, desc = *mapping
          next if mappings['text'][charcode] || mappings['math'][charcode]
          desc = " # #{desc.strip}" if (desc || '').strip != ''
          mappings[mode][charcode] = "  #{char(charcode)}: #{latex.to_json}#{desc}\n"
        }
        %w{math text}.each{|mode|
          mappings[mode] = mappings[mode].keys.sort.collect{|charcode| mappings[mode][charcode] }
          cs.puts "LaTeX.toLaTeX.#{encoding}.#{mode} =\n" + mappings[mode].join('')
        }
      }
      cs.puts "LaTeX.toLaTeX.embrace ="
      @chars.execute('SELECT distinct latex FROM mapping ORDER BY latex'){|mapping|
        latex = mapping[0]
        next unless latex =~ /^\\[a-z]{[^}]+}$/
        cs.puts "  #{latex.to_json}: true"
      }
      cs.puts

      done = {}
      cs.puts "LaTeX.toUnicode ="
      @chars.execute('SELECT charcode, latex, description FROM mapping ORDER BY charcode, preference'){|mapping|
        charcode, latex, desc = *mapping
        next if latex =~ /^[a-z]+$/i || latex.strip == ''
        next if charcode < 256 && latex == charcode.chr
        #latex = latex[1..-2] if latex =~ /^{.+}$/ && latex !~ /}{/
        #latex.sub!(/{}$/, '')
        #next if latex.length < 2
        latex.strip!
        next if done[latex]
        done[latex] = true
        desc = " # #{desc.strip}" if (desc || '').strip != ''
        cs.puts "  #{latex.to_json}: #{char(charcode)}#{desc}"
      }
    }
  end

  def patch_bibtex(target)
    target = File.expand_path(target)

    bbt = OpenStruct.new(mapped: {}, reversed: [])
    bbt.mapped = {}
    @chars.execute("SELECT charcode, latex, mode, description FROM mapping WHERE preference = 0 AND unicode_to_latex IN ('true', 'ascii') ORDER BY charcode"){|mapping|
      charcode, latex, mode, desc = *mapping
      next if bbt.mapped[charcode]
      latex = "$#{latex}$" if mode == 'math'
      desc = " // #{desc.strip}" if (desc || '').strip != ''
      bbt.mapped[charcode] = "\t#{char(charcode)}: #{latex.to_json},#{desc}"
    }

    done = {}
    bbt.reversed = []
    @chars.execute('SELECT charcode, latex, description FROM mapping ORDER BY charcode, preference'){|mapping|
      charcode, latex, desc = *mapping
      next if latex =~ /^[a-z]+$/i || latex.strip == ''
      next if charcode < 256 && latex == charcode.chr
      #latex = latex[1..-2] if latex =~ /^{.+}$/ && latex !~ /}{/
      #latex.sub!(/{}$/, '')
      #next if latex.length < 2
      latex.strip!
      next if done[latex]
      done[latex] = true
      desc = " // #{desc.strip}" if (desc || '').strip != ''
      bbt.reversed << "\t#{latex.to_json}: #{char(charcode)},#{desc}"
    }

    zotero = OpenStruct.new(mapped: [], reversed: [])
    open(target, 'w'){|js|
      state = nil
      IO.readlines('/Users/emile/zotero/translators/BibTeX.js').each_with_index{|line, no|
        if line =~ /var mappingTable = {/
          state = :mapping
        elsif line =~ /var reversemappingTable = {/
          state = :reverse
        elsif line =~ /^};/
          if state == :mapping
            js.puts("\t// BBT")
            bbt.mapped.keys.sort.each{|k|
              next if zotero.mapped.include?(k) || bbt.mapped[k] !~ /'\\u/
              js.puts(bbt.mapped[k])
            }
          elsif state == :reverse
            js.puts("\t// BBT")
            bbt.reversed.sort.each{|tex|
              next if zotero.reversed.include?(tex)
              js.puts(tex)
            }
          end
          state = nil
        elsif line =~ /^\t\/\/Greek/ || line =~ /^\/\* Derived/ || line.strip == '' || line =~ /^\/\* These / || line =~ /^\*\// || line =~ /\/\* Derived/
          # pass
        #elsif line =~ /^\t?\/\// || line =~ /^\/\*/ || line =~ /^\*\// || line =~ /^\t"\\u02BE"/ || line.strip == ''
        # pass
        elsif state == :mapping
          if line =~ /^\t"\\u([0-9A-F]{4})":/
            zotero.mapped << $1.to_i(16)
          elsif  line =~ /^\/\*\t"\\u(02BF)"/
            zotero.mapped << $1.to_i(16)
          elsif line =~ /^\t"([^"])"\s*:/
            zotero.mapped << $1.ord
          else
            throw "#{no + 1} mapping: unrecognized #{line}"
          end
        elsif state == :reverse
          tex = nil
          if line =~ /^\t(".*") *: /
            tex = $1
          elsif line =~ /^\t\/\/("'n")/
            tex = $1
          elsif line =~ /^\s*\/[\/\*] *("[^"]+")/
            tex = $1
          else
            throw "#{no + 1} reverse: unrecognized #{line}"
          end
          zotero.reversed << JSON.parse("{\"tex\": #{tex}}")['tex']
        end

        js.write(line)
      }
    }
  end

  def fixup
    @chars.execute("DELETE from mapping WHERE charcode = 0X219C AND latex = '\\arrowwaveleft' AND mode = 'math'")

    [
      ["\\",    "\\backslash{}",      'math'],
      ['&',     "\\&",                'text'],
      ['$',     "\\$",                'text'],
      [0x00A0,  '~',                  'text'],
      [0x2003,  "\\quad{}",           'text'],
      [0x2004,  "\\;",                'text'],
      [0x2009,  "\\,",                'text'],
      [0x2009,  "\\,",                'text'],
      [0x200B,  "\\hspace{0pt}",      'text'],
      [0x205F,  "\\:",                'text'],
      [0xFFFD,  "\\dbend{}",          'text'],
      [0X219C,  "\\arrowwaveleft{}",  'math'],
      [0x00B0,  '^\\circ{}',          'math'],
      # TODO: replace '}' and '{' with textbrace(left|right) once the bug mentioned in
      # http://tex.stackexchange.com/questions/230750/open-brace-in-bibtex-fields/230754#comment545453_230754
      # is widely enough distributed
      ['_',     "\\_",                'text'],
      ['}',     "\\}",                'text'],
      ['{',     "\\{",                'text'],
    ].each{|patch|
      patch[0] = patch[0].ord if patch[0].is_a?(String)
      @prefer << patch[1]
      @chars.execute("REPLACE INTO mapping (charcode, latex, mode) VALUES (?, ?, ?)", patch)
    }

    @chars.execute("REPLACE INTO mapping (charcode, latex, mode) VALUES (?, ?, ?)", ["`".ord, "\\textasciigrave", 'text'])
    @chars.execute("REPLACE INTO mapping (charcode, latex, mode) VALUES (?, ?, ?)", ["'".ord, "\\textquotesingle", 'text'])
    @chars.execute("REPLACE INTO mapping (charcode, latex, mode) VALUES (?, ?, ?)", [" ".ord, "\\space", 'text'])

    { "\\textdollar"        => "\\$",
      "\\textquotedblleft"  => "``",
      "\\textquotedblright" => "''",
      "\\textasciigrave"    => "`",
      "\\textquotesingle"   => "'",
    }.each_pair{|ist, soll|
      @prefer << soll + '{}'
      template = "SELECT DISTINCT charcode, ?, 'text' FROM mapping WHERE latex IN (?, ?, ?)"
      params = [soll, ist, ist + ' ', ist + '{}']
      raise "No mapping found for #{ist.inspect}" if @chars.execute(template, params).length == 0
      @chars.execute("REPLACE INTO mapping (charcode, latex, mode) #{template}", params)
    }
  end

  def expand
    @chars.execute('SELECT charcode, latex, mode, description FROM mapping').collect{|mapping| mapping}.each{|mapping|
      charcode, latex, mode, description = *mapping
      latex += '{}' if latex =~ /[0-9a-z]$/i
      latex.sub!(/ $/, '{}')

      @chars.execute('INSERT OR IGNORE INTO mapping (charcode, latex, mode, description) VALUES (?, ?, ?, ?)', [charcode, latex, mode, description])
      @chars.execute('INSERT OR IGNORE INTO mapping (charcode, latex, mode, description) VALUES (?, ?, ?, ?)', [charcode, latex.sub(/{}$/, ''), mode, description]) if latex =~ /{}$/

      case latex
        when /^(\\[a-z][^\s]*)\s$/i, /^(\\[^a-z])({}|\s)$/i  # '\ss ', '\& ' => '{\\s}', '{\&}'
          @chars.execute('INSERT OR IGNORE INTO mapping (charcode, latex, mode, description) VALUES (?, ?, ?, ?)', [charcode, "{#{$1}}", mode, description])
          @chars.execute('INSERT OR IGNORE INTO mapping (charcode, latex, mode, description) VALUES (?, ?, ?, ?)', [charcode, "#{$1} ", mode, description])
        when /^\\([^a-z]){(.)}$/                       # '\"{a}' => '\"a', '{\"a}'
          @chars.execute('INSERT OR IGNORE INTO mapping (charcode, latex, mode, description) VALUES (?, ?, ?, ?)', [charcode, "\\#{$1}#{$2} ", mode, description])
          @chars.execute('INSERT OR IGNORE INTO mapping (charcode, latex, mode, description) VALUES (?, ?, ?, ?)', [charcode, "{\\#{$1}#{$2}}", mode, description])
        when /^\\([^a-z])(.)({}|\s)*$/                       # '\"a " => '\"{a}', '{\"a}'
          @chars.execute('INSERT OR IGNORE INTO mapping (charcode, latex, mode, description) VALUES (?, ?, ?, ?)', [charcode, "\\#{$1}{#{$2}}", mode, description])
          @chars.execute('INSERT OR IGNORE INTO mapping (charcode, latex, mode, description) VALUES (?, ?, ?, ?)', [charcode, "{\\#{$1}#{$2}}", mode, description])
          @chars.execute('INSERT OR IGNORE INTO mapping (charcode, latex, mode, description) VALUES (?, ?, ?, ?)', [charcode, "\\#{$1}#{$2}{}", mode, description])
        when /^{\\([^a-z])(.)}$/                        # '{\"a}'
          @chars.execute('INSERT OR IGNORE INTO mapping (charcode, latex, mode, description) VALUES (?, ?, ?, ?)', [charcode, "\\#{$1}#{$2} ", mode, description])
          @chars.execute('INSERT OR IGNORE INTO mapping (charcode, latex, mode, description) VALUES (?, ?, ?, ?)', [charcode, "\\#{$1}{#{$2}}", mode, description])
        when /^{(\^[0-9])}$/
          @chars.execute('INSERT OR IGNORE INTO mapping (charcode, latex, mode, description) VALUES (?, ?, ?, ?)', [charcode, $1, mode, description])
        when /^{(\\.+)}$/                             # '{....}' '.... '
          @chars.execute('INSERT OR IGNORE INTO mapping (charcode, latex, mode, description) VALUES (?, ?, ?, ?)', [charcode, "#{$1} ", mode, description])
          @chars.execute('INSERT OR IGNORE INTO mapping (charcode, latex, mode, description) VALUES (?, ?, ?, ?)', [charcode, "#{$1}{}", mode, description])
        when /^(\\.*)({}| )$/
          @chars.execute('INSERT OR IGNORE INTO mapping (charcode, latex, mode, description) VALUES (?, ?, ?, ?)', [charcode, "{#{$1}}", mode, description])
          @chars.execute('INSERT OR IGNORE INTO mapping (charcode, latex, mode, description) VALUES (?, ?, ?, ?)', [charcode, "#{$1} ", mode, description])
      end
    }

    # remove dups
    @chars.execute("DELETE FROM mapping WHERE latex <> trim(latex) AND trim(latex) in (SELECT latex FROM mapping)")
    @chars.execute('UPDATE mapping SET latex = trim(latex)')
  end

  def read_milde
    header = nil
    IO.readlines(open('http://milde.users.sourceforge.net/LUCR/Math/data/unimathsymbols.txt')).each{|line|
      if line =~ /^#/
        header = line.sub(/^#/, '').strip.split('^')
      else
        char = Hash[*header.zip(line.split('^').collect{|v| v == '' ? nil : v}).flatten]
        addchar(char['no.'].to_i(16), char['LaTeX'] || char['unicode-math'], 'math', char['comments'])
      end
    }
  end

  def read(xml)
    pbar = nil
    mapping = nil
    open(xml,
      content_length_proc: lambda {|t|
        if t && t > 0
          pbar = ProgressBar.new(xml, t)
          pbar.file_transfer_mode
        end
      },
      progress_proc: lambda {|s|
        pbar.set s if pbar
    }) {|f|
      mapping = Nokogiri::XML(f)
    }

    mapping.xpath('//character').each{|char|
      latex = char.at('.//latex')
      next unless latex
      next if char['id'] =~ /-/

      latex = latex.inner_text
      mode = (char['mode'] == 'math' ? 'math' : 'text')
      charcode = char['id'].sub(/^u/i, '').to_i(16)

      description = char.at('.//unicodedata[@unicode1]')
      description = description['unicode1'].to_s.strip if description
      if !description || description.strip == ''
        description = char.at('.//description')
        description = description.inner_text if description
      end
      description ||= ''

      addchar(charcode, latex, mode, description)
    }
  end

  def addchar(charcode, latex, mode, description)
    return if latex == '' || latex.nil?
    if charcode >= 0x20 && charcode <= 0x7E
      chr = charcode.chr
      # removed [ ]
      return if chr =~ /^[\x20-\x7E]$/ && ! %w{# $ % & ~ _ ^ { } > < \\}.include?(chr)
      return if chr == latex && mode == 'text'
    end
    latex = "{\\#{$1}#{$2}}" if latex =~ /^\\(["^`\.'~]){([^}]+)}$/
    latex = "{\\#{$1} #{$2}}" if latex =~ /^\\([cuHv]){([^}]+)}$/

    @chars.execute("DELETE FROM mapping where charcode = ?", [charcode])
    @chars.execute("INSERT INTO mapping (charcode, latex, mode, description) VALUES (?, ?, ?, ?)", [charcode, latex, mode, description])
  end

  def download(force=true)
    File.unlink(@@cache) if File.file?(@@cache) && force
    @chars = SQLite3::Database.new(@@cache)
    @chars.execute('PRAGMA synchronous = OFF')
    @chars.execute('PRAGMA journal_mode = MEMORY')
    @chars.results_as_hash

    @prefer = []
    # prefered option is braces-over-traling-space because of miktex bug that doesn't ignore spaces after commands
    # https://github.com/retorquere/zotero-better-bibtex/issues/69
    @chars.create_function('rank', 1) do |func, latex, mode|
      latex = latex.to_s
      tests = [
        lambda{ @prefer.include?(latex) },
        lambda{ latex !~ /\\/ || latex == "\\$" || latex =~ /^\\[^a-zA-Z0-9]$/ || latex =~ /^\\\^[1-3]$/ },
        lambda{ latex =~ /^(\\[0-9a-zA-Z]+)+{}$/ },
        lambda{ latex =~ /^{.+}$/ },
        lambda{ latex =~ /}/ },
        lambda{ true }
      ]
      tests.each_with_index{|test, i|
        next unless test.call
        func.result = (i * 2) + (mode == 'text' ? 0 : 1)
        break
      }
    end

    if @chars.get_first_value("SELECT count(*) FROM sqlite_master WHERE type='table' AND name='mapping'") != 1
      @chars.execute("""
        CREATE TABLE mapping (
          charcode NOT NULL,
          latex NOT NULL,
          mode CHECK (mode IN ('text', 'math')),
          unicode_to_latex DEFAULT 'false' CHECK (unicode_to_latex IN ('true', 'false', 'ascii')),
          preference NOT NULL DEFAULT 0,
          description,

          UNIQUE(charcode, latex)
        )
      """)
      @chars.transaction

      read_milde
      read('http://www.w3.org/2003/entities/2007xml/unicode.xml')
      read('http://www.w3.org/Math/characters/unicode.xml')

      self.fixup
      self.expand

      @chars.execute("""UPDATE mapping SET unicode_to_latex = CASE
        WHEN mode = 'text' AND (charcode = 0x20 OR charcode BETWEEN 0x20 AND 0x7E AND CHAR(charcode) = latex) THEN
          'false'
        WHEN charcode = 0x00A0 OR charcode BETWEEN 0x20 AND 0x7E THEN
          'true'
        ELSE
          'ascii'
        END""")

      @chars.execute("UPDATE mapping SET preference = rank(latex, mode)")
      preference = {}
      @chars.execute("""
              SELECT charcode, latex
              FROM mapping
              ORDER BY preference, mode, LENGTH(latex), latex, charcode"""){|mapping|
        charcode, latex = *mapping
        preference[charcode] ||= []
        preference[charcode] << latex
      }
      preference.each_pair{|charcode, latexen|
        latexen.each_with_index{|latex, p|
          @chars.execute('UPDATE mapping SET preference = ? WHERE charcode = ? AND latex = ?', [p, charcode, latex])
        }
      }
      @chars.commit

      puts "#{@@cache} saved"
    end
  end

  def mapping(target)
    download(false)
    save(target)
  end

  def zotero_patch(target)
    download(false)
    patch_bibtex(target)
  end

  def pegjs(source, target)
    download(false)
    save(target, source)
  end

  def patterns(source, target)
    download(false)

    patterns = {
      /^\\fontencoding\{[^\}]+\}\\selectfont\\char[0-9]+$/      => {terminated: false},
      /^\\acute\{\\ddot\{\\[a-z]+\}\}$/                         => {terminated: true},
      /^\\fontencoding\{[^\}]+\}\\selectfont\\char[0-9]+$/      => {terminated: false},
      /^\\cyrchar\{\\'\\[a-zA-Z]+\}$/                           => {terminated: true},
      /^\\u \\i$/                                               => {terminated: false},
      /^\\[~\^'`"]\\[ij]$/                                      => {terminated: false},
      /^\\=\{\\i\}$/                                            => {terminated: true},
      /^\\[Huvc] [a-zA-Z]$/                                     => {terminated: false},
      /^\\mathrm\{[^\}]+\}$/                                    => {terminated: true},
      /^\\[a-zA-Z]+\{\\?[0-9a-zA-Z]+\}(\{\\?[0-9a-zA-Z]+\})?$/  => {terminated: true},
      /^\\[a-z]+\\[a-zA-Z]+$/                                   => {terminated: false},
      /^\\[a-z]+\{[,\.a-z0-9]+\}$/                              => {terminated: true},
      /^\\[0-9a-zA-Z]+$/                                        => {terminated: false},
      /^\^[123] ?$/                                             => {terminated: true},
      /^\^\{[123]\}$/                                           => {terminated: true},
      /^\\[\.~\^'`"]\{[a-zA-Z]\}$/                              => {terminated: true},
      /^\\[=kr]\{[a-zA-Z]\}$/                                   => {terminated: true},
      /^\\[\.=][a-zA-Z]$/                                       => {terminated: false},
      /^\^\\circ$/                                              => {terminated: false},
      /^''+$/                                                   => {terminated: true},
      /^\\[~\^'`"][a-zA-Z] ?$/                                  => {terminated: true},
      /^\\[^a-zA-Z0-9]$/                                        => {terminated: true},
      /^\\ddot\{\\[a-z]+\}$/                                    => {terminated: true},
      /^~$/                                                     => {terminated: true},
      /^\\sqrt\[[234]\]$/                                       => {terminated: true},

      # unterminated
      /^\\sim\\joinrel\\leadsto$/                               => {terminated: false, exclude: true},
      /^\\mathchar\"2208$/                                      => {terminated: false, exclude: true},
      /^\\'\{\}[a-zA-Z]$/                                       => {terminated: false, exclude: true},
      /^_\\ast$/                                                => {terminated: false, exclude: true},
      /^'n$/                                                    => {terminated: false, exclude: true},
      /^\\int(\\!\\int)+$/                                      => {terminated: false, exclude: true},
      /^\\not\\kern-0.3em\\times$/                              => {terminated: false, exclude: true},
      # terminated
      /^\\Pisymbol\{[a-z0-9]+\}\{[0-9]+\}$/                     => {terminated: true, exclude: true},
      /^\{\/\}\\!\\!\{\/\}$/                                    => {terminated: true, exclude: true},
      /^\\stackrel\{\*\}\{=\}$/                                 => {terminated: true, exclude: true},
      /^<\\kern-0.58em\($/                                      => {terminated: true, exclude: true},
      /^\\fbox\{~~\}$/                                          => {terminated: true, exclude: true},
      /^\\not[<>]$/                                             => {terminated: true, exclude: true},
      /^\\ensuremath\{\\[a-zA-Z0-9]+\}$/                        => {terminated: true, exclude: true},
      /^[-`,\.]+$/                                              => {terminated: true, exclude: true},
      /^\\rule\{1em\}\{1pt\}$/                                  => {terminated: true, exclude: true},
      /^\\'\$\\alpha\$$/                                        => {terminated: true, exclude: true},
      /^\\mathrm\{\\ddot\{[A-Z]\}\}$/                           => {terminated: true, exclude: true},
      /^\\'\{\}\{[a-zA-Z]\}$/                                   => {terminated: true, exclude: true},
      /^'$/                                                     => {terminated: true, exclude: true},
      /^\\mathbin\{\{:\}\\!\\!\{-\}\\!\\!\{:\}\}$/              => {terminated: true, exclude: true},
      /^\\not =$/                                               => {terminated: true, exclude: true},
      /^=:$/                                                    => {terminated: true, exclude: true},
      /^:=$/                                                    => {terminated: true, exclude: true},
      /^:$/                                                     => {terminated: true, exclude: true},
    }

    @chars.execute('SELECT DISTINCT charcode, latex FROM mapping').each{|mapping|
      charcode, latex = *mapping
      latex.strip! if latex != ' '
      latex = latex[1..-2] if latex =~ /^{.+}$/ && latex !~ /}{/
      latex.sub!(/{}$/, '')
      next if charcode < 256 && latex == charcode.chr
      next if latex =~ /^[a-z]+$/i || latex.strip == ''

      patterns.detect{|(p, s)|
        if p =~ latex
          s[:count] = s[:count].to_i + 1
          true
        else
          false
        end
      } || raise("No pattern for #{latex.inspect}")
    }

    open(target, 'w'){|t|
      t.puts(open(source).read)
      t.puts "lookup\n"
      prefix = nil

      patterns.each_with_index {|(re, state), i|
        next if state[:exclude] # || state[:count].to_i == 0
        #next unless p.max > 1
        if prefix.nil?
          prefix = "  ="
        else
          prefix = "  /"
        end
        rule = prefix
        rule += " text:(#{pegjs_re(re)})"
        rule = rule.ljust(70, ' ')

        rule += " terminator" unless state[:terminated]
        rule = rule.ljust(85, ' ')
        rule += " &{ return lookup(text, #{i}); }"
        rule = rule.ljust(110, ' ')
        rule += "{ return lookup(text); }"

        t.puts rule
      }
    }
  end

  def pegjs_re(re)
    pegjs = ''
    Regexp::Scanner.scan re  do |type, token, text, ts, te|
      #puts "type == #{type.inspect} && token == #{token.inspect} #  text: '#{text.inspect}' [#{ts.inspect}..#{te.inspect}]"

      if type == :anchor
        # pass
      elsif type == :escape && token == :interval_open #  text: '"\\{"' [32..34]
        pegjs += "\t\"{\"\t"
      elsif type == :escape && token == :interval_close #  text: '"\\}"' [49..51]
        pegjs += "\t\"}\"\t"
      elsif type == :escape || type == :literal
        pegjs += "\t\"" + text + "\"\t"
      elsif type == :set && token == :open #  text: '"["' [3..4]
        pegjs += '['
      elsif type == :set && token == :range #  text: '"a-z"' [4..7]
        pegjs += text
      elsif type == :set && token == :close #  text: '"]"' [10..11]
        pegjs += ']'
      elsif type == :set && token == :escape && text == "\\}"
        pegjs += '}'
      elsif type == :set && token == :escape
        pegjs += text
      elsif type == :set && token == :member
        pegjs += text
      elsif type == :quantifier
        pegjs += text + ' '
      elsif type == :set && token == :negate
        pegjs += text
      elsif type == :group
        pegjs += text
      else
        raise "re: #{re}, type: #{type.inspect}, token: #{token.inspect}, text: #{text.inspect} [#{ts.inspect}..#{te.inspect}]"
      end
    end

    pegjs.gsub!(/("[^"]+")\t\?/, "\n\\1? ")
    pegjs.gsub!(/"\t\t"/, '')
    pegjs.gsub!(/\t+/, ' ')
    pegjs.gsub!(/\n/, '')
    pegjs.gsub!(/ +/, ' ')
    pegjs.strip!
    return pegjs
  end
end

if __FILE__ == $0
  UnicodeConverter.new.zotero_patch('BibTeX.js')
end
