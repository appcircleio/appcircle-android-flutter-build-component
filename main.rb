require 'yaml'
require 'open3'

def get_env_variable(key)
	return (ENV[key] == nil || ENV[key] == "") ? nil : ENV[key]
end

ac_output_type = get_env_variable("AC_OUTPUT_TYPE") || abort('Missing output type.')
ac_flutter_build_mode = get_env_variable("AC_FLUTTER_BUILD_MODE") || abort('Missing flutter build mode.')
ac_flutter_build_extra_args = get_env_variable("AC_FLUTTER_BUILD_EXTRA_ARGS") || ""
ac_project_path = get_env_variable("AC_PROJECT_PATH") || "."

def run_command(command)
    puts "@[command] #{command}"
    status = nil
    stdout_str = nil
    stderr_str = nil

    Open3.popen3(command) do |stdin, stdout, stderr, wait_thr|
        stdout.each_line do |line|
            puts line
        end
        stdout_str = stdout.read
        stderr_str = stderr.read
        status = wait_thr.value
    end

    unless status.success?
        puts stderr_str
        raise stderr_str
    end
    return stdout_str
end

build_type = (ac_output_type == "aab") ? "appbundle" : "apk"
run_command("cd #{ac_project_path} && flutter build #{build_type} #{ac_flutter_build_extra_args} --#{ac_flutter_build_mode}")

build_outputs_folder = "#{ENV["AC_REPOSITORY_DIR"]}/build/app/outputs"
apk_filter_pattern = "#{build_outputs_folder}/apk/**/*.apk"
aab_filter_pattern = "#{build_outputs_folder}/bundle/**/*.apk"

puts "Filtering artifacts: #{apk_filter_pattern}, #{aab_filter_pattern}"

apks = Dir.glob("#{apk_filter_pattern}")
aabs = Dir.glob("#{aab_filter_pattern}")

FileUtils.cp apks, "#{ac_output_folder}"
FileUtils.cp aabs, "#{ac_output_folder}"

apks = Dir.glob("#{ac_output_folder}/**/*.apk").join("|")
aabs = Dir.glob("#{ac_output_folder}/**/*.aab").join("|")

puts "Exporting AC_APK_PATH=#{apks}"
puts "Exporting AC_AAB_PATH=#{aabs}"

open(ENV['AC_ENV_FILE_PATH'], 'a') { |f|
    f.puts "AC_APK_PATH=#{apks}"
    f.puts "AC_AAB_PATH=#{aabs}"
}

exit 0
