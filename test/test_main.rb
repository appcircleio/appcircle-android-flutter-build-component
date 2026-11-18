# frozen_string_literal: true

# ─── Coverage (must start before loading main.rb) ─────────────────────────────
unless defined?(Coverage) && Coverage.running?
  require 'coverage'
  Coverage.start
end

# ─── Dependencies ─────────────────────────────────────────────────────────────
require 'rspec'
require 'rspec/core/formatters/base_formatter'
require 'open3'
require 'fileutils'
require 'tmpdir'
require 'rbconfig'

MAIN_RB      = File.expand_path('../main.rb', __dir__)
PROJECT_ROOT = File.dirname(MAIN_RB)
# Absolute interpreter path, so subprocess tests still work when PATH is unset.
RUBY_BIN     = RbConfig.ruby

require MAIN_RB

# ─── Custom Formatter ─────────────────────────────────────────────────────────
class ReadableFormatter < RSpec::Core::Formatters::BaseFormatter
  RSpec::Core::Formatters.register(
    self,
    :example_group_started,
    :example_group_finished,
    :example_passed,
    :example_failed,
    :example_pending,
    :dump_summary
  )

  PASS  = "\e[32;1m[ PASS ]\e[0m"
  FAIL  = "\e[31;1m[ FAIL ]\e[0m"
  ERROR = "\e[31;1m[ERROR ]\e[0m"
  SKIP  = "\e[33;1m[ SKIP ]\e[0m"

  DIVIDER     = "\e[90m#{'─' * 72}\e[0m"
  DIVIDER_FAT = "\e[90m#{'═' * 72}\e[0m"

  def initialize(output)
    super
    @depth    = 0
    @failures = []
    @counts   = { passed: 0, failed: 0, pending: 0 }
  end

  # Top-level describe groups cycle through distinct colors
  GROUP_COLORS = [
    "\e[34;1m",  # bold blue
    "\e[35;1m",  # bold magenta
    "\e[36;1m",  # bold cyan
    "\e[33;1m",  # bold yellow
  ].freeze

  def example_group_started(notification)
    group = notification.group
    if group.parent_groups.size <= 1
      output.puts if @depth.zero?
      color = GROUP_COLORS[@depth % GROUP_COLORS.size]
      output.puts "  #{color}#{group.description}\e[0m"
    else
      output.puts "    #{'  ' * (@depth - 1)}\e[90m▸ \e[0m\e[37m#{group.description}\e[0m"
    end
    @depth += 1
  end

  def example_group_finished(_notification)
    @depth -= 1 if @depth > 0
  end

  def example_passed(notification)
    @counts[:passed] += 1
    print_example(PASS, notification.example)
  end

  def example_failed(notification)
    @counts[:failed] += 1
    ex    = notification.example
    exc   = ex.execution_result.exception
    badge = exc.is_a?(RSpec::Expectations::ExpectationNotMetError) ? FAIL : ERROR
    print_example(badge, ex)
    @failures << notification
  end

  def example_pending(notification)
    @counts[:pending] += 1
    ex = notification.example
    output.puts "    #{'  ' * [0, @depth - 1].max}#{SKIP}  #{ex.description}"
  end

  def dump_summary(notification)
    output.puts
    output.puts DIVIDER_FAT

    unless @failures.empty?
      output.puts "\n  \e[1;31mFailures:\e[0m\n"
      @failures.each_with_index do |n, i|
        ex  = n.example
        exc = ex.execution_result.exception
        output.puts "  \e[1m#{i + 1}) #{ex.full_description}\e[0m"
        exc.message.lines.first(6).each do |line|
          output.puts "     \e[31m#{line.rstrip}\e[0m"
        end
        output.puts "     \e[90m# #{ex.location}\e[0m"
        output.puts
      end
      output.puts DIVIDER
    end

    t   = notification.examples.size
    p   = @counts[:passed]
    f   = @counts[:failed]
    s   = @counts[:pending]
    sec = format('%.3fs', notification.duration)

    parts = ["\e[32m#{p} passed\e[0m"]
    parts << "\e[31m#{f} failed\e[0m"  if f > 0
    parts << "\e[33m#{s} pending\e[0m" if s > 0

    overall = f.zero? ? "\e[32;1m✔  All #{t} tests passed\e[0m" : "\e[31;1m✖  #{f} of #{t} tests failed\e[0m"
    output.puts "\n  #{overall}"
    output.puts "  #{parts.join('  |  ')}  \e[90m(#{sec})\e[0m"
    output.puts DIVIDER_FAT
  end

  private

  def print_example(badge, example)
    indent = '  ' * [0, @depth - 1].max
    time   = format('%.3fs', example.execution_result.run_time)
    output.puts "    #{indent}#{badge}  #{example.description}  \e[90m(#{time})\e[0m"
  end
end

# ─── Helpers ──────────────────────────────────────────────────────────────────

# Every ENV key main.rb reads. Subprocess tests unset all of them by default so
# the ambient shell environment can never leak into a "missing variable" test.
MAIN_ENV_KEYS = %w[
  AC_FLUTTER_PROJECT_DIR
  AC_OUTPUT_TYPE
  AC_OUTPUT_DIR
  AC_ENV_FILE_PATH
  AC_FLUTTER_BUILD_EXTRA_ARGS
  AC_FLUTTER_BUILD_MODE
  PATH
].freeze

def write_executable(path, content)
  File.write(path, content)
  File.chmod(0o755, path)
end

# Creates a fake `flutter` inside <base>/bin. It never runs the real SDK: it
# records its arguments plus working directory to <base>/flutter.log and drops
# placeholder artifacts where `flutter build` would put them:
#   apk       -> build/app/outputs/apk/release/app-release.apk
#                build/app/outputs/flutter-apk/app-release.apk
#   appbundle -> build/app/outputs/bundle/release/app-release.aab
# Returns { bin:, log: }.
def build_fake_flutter(base)
  bin = File.join(base, 'bin')
  log = File.join(base, 'flutter.log')
  FileUtils.mkdir_p(bin)

  write_executable(File.join(bin, 'flutter'), <<~SH)
    #!/bin/sh
    echo "$(pwd)|flutter $*" >> "#{log}"
    out=build/app/outputs
    case "$2" in
      apk)
        mkdir -p "$out/apk/release" "$out/flutter-apk"
        echo apk > "$out/apk/release/app-release.apk"
        echo apk > "$out/flutter-apk/app-release.apk"
        ;;
      appbundle)
        mkdir -p "$out/bundle/release"
        echo aab > "$out/bundle/release/app-release.aab"
        ;;
    esac
  SH

  { bin: bin, log: log }
end

# Run main.rb in a subprocess with the given ENV hash. Keys set to nil are
# removed from the child environment. PATH defaults to the fake flutter plus
# the minimal system dirs needed for `sh` / `cd` / `mkdir`, so the real
# Flutter SDK is never reachable from these tests.
def run_main(env, fake_bin:)
  clean_env = MAIN_ENV_KEYS.to_h { |k| [k, nil] }
  clean_env['PATH'] = "#{fake_bin}:/usr/bin:/bin"
  Open3.capture3(clean_env.merge(env), "#{RUBY_BIN} #{MAIN_RB}")
end

def commands_in(stdout)
  stdout.lines.grep(/^@@\[command\] /).map { |l| l.sub('@@[command] ', '').chomp }
end

# ─── Tests ────────────────────────────────────────────────────────────────────

RSpec.describe 'loading main.rb' do
  it 'defines the helper functions without running the step' do
    expect(respond_to?(:get_env_variable, true)).to be(true)
    expect(respond_to?(:run_command, true)).to be(true)
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe '#get_env_variable' do
  around do |example|
    old = ENV['_TEST_VAR']
    example.run
    if old.nil?
      ENV.delete('_TEST_VAR')
    else
      ENV['_TEST_VAR'] = old
    end
  end

  it 'returns the value when the key is set' do
    ENV['_TEST_VAR'] = 'hello'
    expect(get_env_variable('_TEST_VAR')).to eq('hello')
  end

  it 'preserves surrounding whitespace in the value' do
    ENV['_TEST_VAR'] = ' --split-per-abi '
    expect(get_env_variable('_TEST_VAR')).to eq(' --split-per-abi ')
  end

  it 'returns nil when the key is missing' do
    ENV.delete('_TEST_VAR')
    expect(get_env_variable('_TEST_VAR')).to be_nil
  end

  it 'returns nil when the value is an empty string' do
    ENV['_TEST_VAR'] = ''
    expect(get_env_variable('_TEST_VAR')).to be_nil
  end

  it 'lets callers fall back to a default with ||' do
    ENV.delete('_TEST_VAR')
    expect(get_env_variable('_TEST_VAR') || 'release').to eq('release')
  end

  it 'lets callers abort on a missing required variable' do
    ENV.delete('_TEST_VAR')
    allow($stderr).to receive(:write)
    expect { get_env_variable('_TEST_VAR') || abort('Missing _TEST_VAR.') }
      .to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe '#run_command' do
  context 'happy path' do
    it 'passes the exact composed command string to system' do
      cmd = 'cd /tmp/project && flutter build apk  --release'
      expect(self).to receive(:system).with(cmd).and_return(true)
      expect { run_command(cmd) }.to output("@@[command] #{cmd}\n").to_stdout
    end

    it 'does not exit when the command succeeds' do
      allow(self).to receive(:system).and_return(true)
      allow($stdout).to receive(:puts)
      expect { run_command('flutter build apk') }.not_to raise_error
    end
  end

  context 'empty / nil input' do
    it 'raises ArgumentError with context when the command is nil' do
      expect { run_command(nil) }.to raise_error(ArgumentError, /run_command: expected a non-empty command, got nil/)
    end

    it 'raises ArgumentError when the command is an empty string' do
      expect { run_command('') }.to raise_error(ArgumentError, /got ""/)
    end

    it 'raises ArgumentError when the command is only whitespace' do
      expect { run_command('   ') }.to raise_error(ArgumentError, /non-empty command/)
    end

    it 'does not shell out for an invalid command' do
      expect(self).not_to receive(:system)
      expect { run_command(nil) }.to raise_error(ArgumentError)
    end
  end

  context 'error branch – command fails' do
    before { allow($stdout).to receive(:puts) }

    it 'exits with SystemExit when the command exits non-zero' do
      expect { run_command('false') }.to raise_error(SystemExit)
    end

    it 'propagates the exact non-zero exit status' do
      expect { run_command('sh -c "exit 3"') }
        .to raise_error(SystemExit) { |e| expect(e.status).to eq(3) }
    end

    it 'exits 1 instead of crashing when the command is killed by a signal' do
      expect { run_command('sh -c "kill -9 $$"') }
        .to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
    end

    it 'exits 127 when the executable cannot be found' do
      expect { run_command('__ac_definitely_not_a_command__') }
        .to raise_error(SystemExit) { |e| expect(e.status).to eq(127) }
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe 'ENV validation' do
  let(:tmpdir)   { Dir.mktmpdir('ac_flutter_build_env_test') }
  let(:fake)     { build_fake_flutter(tmpdir) }
  let(:project)  { FileUtils.mkdir_p(File.join(tmpdir, 'project')).first }
  let(:out_dir)  { FileUtils.mkdir_p(File.join(tmpdir, 'output')).first }
  let(:env_file) { File.join(tmpdir, 'ac_env') }

  after { FileUtils.rm_rf(tmpdir) }

  # Everything set correctly; each context below removes or blanks one variable.
  let(:valid_env) do
    {
      'AC_FLUTTER_PROJECT_DIR' => project,
      'AC_OUTPUT_TYPE'         => 'apk',
      'AC_OUTPUT_DIR'          => out_dir,
      'AC_ENV_FILE_PATH'       => env_file
    }
  end

  shared_examples 'a failing validation' do |expected_pattern|
    it "exits non-zero and stderr matches #{expected_pattern.inspect}" do
      _out, err, status = run_main(env, fake_bin: fake[:bin])
      expect(status.exitstatus).to eq(1)
      expect(err).to match(expected_pattern)
    end

    it 'does not run flutter or write the env file' do
      out, = run_main(env, fake_bin: fake[:bin])
      expect(commands_in(out)).to be_empty
      expect(File).not_to exist(fake[:log])
      expect(File).not_to exist(env_file)
    end
  end

  {
    'AC_FLUTTER_PROJECT_DIR' => /Missing Flutter project path\./,
    'AC_OUTPUT_TYPE'         => /Missing output type\./,
    'AC_OUTPUT_DIR'          => /Missing output folder\./,
    'AC_ENV_FILE_PATH'       => /Missing env file path\./,
    'PATH'                   => /Missing PATH\./
  }.each do |key, message|
    context "#{key} is missing" do
      let(:env) { valid_env.merge(key => nil) }
      include_examples 'a failing validation', message
    end

    context "#{key} is empty string" do
      let(:env) { valid_env.merge(key => '') }
      include_examples 'a failing validation', message
    end
  end

  context 'optional variables' do
    it 'succeeds without AC_FLUTTER_BUILD_EXTRA_ARGS and AC_FLUTTER_BUILD_MODE' do
      _out, err, status = run_main(valid_env, fake_bin: fake[:bin])
      expect(status.exitstatus).to eq(0), "stderr: #{err}"
      expect(err).to eq('')
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe 'build flow (fake flutter)' do
  let(:tmpdir)   { Dir.mktmpdir('ac_flutter_build_flow_test') }
  let(:fake)     { build_fake_flutter(tmpdir) }
  let(:project)  { FileUtils.mkdir_p(File.join(tmpdir, 'project')).first }
  let(:out_dir)  { FileUtils.mkdir_p(File.join(tmpdir, 'output')).first }
  let(:env_file) { File.join(tmpdir, 'ac_env') }

  after { FileUtils.rm_rf(tmpdir) }

  let(:base_env) do
    {
      'AC_FLUTTER_PROJECT_DIR' => project,
      'AC_OUTPUT_TYPE'         => 'apk',
      'AC_OUTPUT_DIR'          => out_dir,
      'AC_ENV_FILE_PATH'       => env_file
    }
  end

  context 'composed flutter command' do
    it 'builds an apk in release mode by default' do
      out, err, status = run_main(base_env, fake_bin: fake[:bin])
      expect(status.exitstatus).to eq(0), "stderr: #{err}"
      expect(commands_in(out)).to eq(["cd #{project} && flutter build apk  --release"])
    end

    it 'runs flutter inside AC_FLUTTER_PROJECT_DIR' do
      run_main(base_env, fake_bin: fake[:bin])
      dir, args = File.read(fake[:log]).chomp.split('|', 2)
      expect(File.realpath(dir)).to eq(File.realpath(project))
      expect(args).to eq('flutter build apk --release')
    end

    it 'maps AC_OUTPUT_TYPE=aab to `flutter build appbundle`' do
      out, = run_main(base_env.merge('AC_OUTPUT_TYPE' => 'aab'), fake_bin: fake[:bin])
      expect(commands_in(out)).to eq(["cd #{project} && flutter build appbundle  --release"])
    end

    it 'treats any other AC_OUTPUT_TYPE as apk' do
      out, = run_main(base_env.merge('AC_OUTPUT_TYPE' => 'AAB'), fake_bin: fake[:bin])
      expect(commands_in(out)).to eq(["cd #{project} && flutter build apk  --release"])
    end

    it 'honours AC_FLUTTER_BUILD_MODE and AC_FLUTTER_BUILD_EXTRA_ARGS' do
      env = base_env.merge('AC_FLUTTER_BUILD_MODE'       => 'profile',
                           'AC_FLUTTER_BUILD_EXTRA_ARGS' => '--split-per-abi --flavor dev')
      out, = run_main(env, fake_bin: fake[:bin])
      expect(commands_in(out)).to eq(["cd #{project} && flutter build apk --split-per-abi --flavor dev --profile"])
    end

    it 'prints the PATH it runs with' do
      out, = run_main(base_env, fake_bin: fake[:bin])
      expect(out).to include("PATH=#{fake[:bin]}:/usr/bin:/bin\n")
    end
  end

  context 'artifacts and output variables' do
    it 'copies apks (incl. flutter-apk) to AC_OUTPUT_DIR and exports AC_APK_PATH' do
      run_main(base_env, fake_bin: fake[:bin])
      expect(Dir.children(out_dir)).to eq(['app-release.apk'])
      expect(File.read(env_file)).to eq("AC_APK_PATH=#{out_dir}/app-release.apk\nAC_AAB_PATH=\n")
    end

    it 'copies aabs to AC_OUTPUT_DIR and exports AC_AAB_PATH' do
      run_main(base_env.merge('AC_OUTPUT_TYPE' => 'aab'), fake_bin: fake[:bin])
      expect(Dir.children(out_dir)).to eq(['app-release.aab'])
      expect(File.read(env_file)).to eq("AC_APK_PATH=\nAC_AAB_PATH=#{out_dir}/app-release.aab\n")
    end

    it 'joins multiple artifacts with |' do
      FileUtils.mkdir_p(File.join(project, 'build/app/outputs/apk/debug'))
      File.write(File.join(project, 'build/app/outputs/apk/debug/app-debug.apk'), 'apk')
      run_main(base_env, fake_bin: fake[:bin])
      apk_line = File.read(env_file).lines.first.chomp
      expect(apk_line.sub('AC_APK_PATH=', '').split('|').sort)
        .to eq(["#{out_dir}/app-debug.apk", "#{out_dir}/app-release.apk"])
    end

    it 'appends to an existing env file instead of overwriting it' do
      File.write(env_file, "EXISTING=1\n")
      run_main(base_env, fake_bin: fake[:bin])
      expect(File.read(env_file)).to start_with("EXISTING=1\nAC_APK_PATH=")
    end

    it 'exports empty paths when the build produced no artifacts' do
      write_executable(File.join(fake[:bin], 'flutter'), "#!/bin/sh\nexit 0\n")
      _out, err, status = run_main(base_env, fake_bin: fake[:bin])
      expect(status.exitstatus).to eq(0), "stderr: #{err}"
      expect(File.read(env_file)).to eq("AC_APK_PATH=\nAC_AAB_PATH=\n")
    end
  end

  context 'when flutter build fails' do
    before do
      write_executable(File.join(fake[:bin], 'flutter'), <<~SH)
        #!/bin/sh
        echo "flutter blew up" >&2
        exit 2
      SH
    end

    it 'exits with the flutter exit status and surfaces its stderr' do
      _out, err, status = run_main(base_env, fake_bin: fake[:bin])
      expect(status.exitstatus).to eq(2)
      expect(err).to include('flutter blew up')
    end

    it 'does not copy artifacts or write the env file' do
      run_main(base_env, fake_bin: fake[:bin])
      expect(Dir.children(out_dir)).to be_empty
      expect(File).not_to exist(env_file)
    end
  end
end

# ─── Coverage Report ──────────────────────────────────────────────────────────
def print_coverage_report
  return unless defined?(Coverage) && Coverage.running?

  result = begin
    Coverage.result(stop: false, clear: false)
  rescue ArgumentError
    Coverage.result
  end

  main_path = result.keys.find { |p| p&.end_with?('main.rb') }
  return puts("\nCoverage: main.rb not found in results") unless main_path

  data      = result[main_path]
  lines     = data.each_with_index.reject { |c, _| c.nil? }
  total     = lines.size
  covered   = lines.count { |c, _| c.to_i > 0 }
  pct       = total.positive? ? (covered * 100.0 / total).round(1) : 100.0
  uncovered = lines.select { |c, _| c.to_i == 0 }.map { |_, i| i + 1 }

  color = pct == 100 ? "\e[32;1m" : pct >= 80 ? "\e[33m" : "\e[31m"
  bar_filled = (pct / 5).round
  bar = "\e[32m" + '█' * bar_filled + "\e[90m" + '░' * (20 - bar_filled) + "\e[0m"

  puts "\n\e[90m#{'═' * 72}\e[0m"
  puts '  Coverage Report'
  puts "\e[90m#{'─' * 72}\e[0m"
  puts "  main.rb  #{bar}  #{color}#{pct}%\e[0m  (#{covered}/#{total} lines)"
  if uncovered.any? && uncovered.size <= 20
    puts "  Uncovered lines: \e[90m#{uncovered.join(', ')}\e[0m"
  elsif uncovered.any?
    puts "  Uncovered lines: \e[90m#{uncovered.first(15).join(', ')} … (+#{uncovered.size - 15} more)\e[0m"
  end
  puts "  \e[90m(in-process coverage only; the guarded main flow is exercised via subprocess tests)\e[0m"
  puts "\e[90m#{'═' * 72}\e[0m"
end

# ─── Runner ───────────────────────────────────────────────────────────────────
if __FILE__ == $PROGRAM_NAME
  RSpec.configure do |config|
    config.add_formatter ReadableFormatter
    config.color        = true
    config.order        = :defined
  end

  exit_code = RSpec::Core::Runner.run(['--order', 'defined'])
  print_coverage_report
  exit exit_code
end
