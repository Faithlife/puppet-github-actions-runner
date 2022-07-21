# == Define github_actions_runner::instance
#
#  Configure and deploy actions runners instances
#
# * ensure
#  Enum, Determine if to add or remove the resource.
#
# * org_name
# String, actions runner org name.(Default: Value set by github_actions_runner Class)
#
# * personal_access_token
# String, GitHub PAT with admin permission on the repositories or the origanization.(Default: Value set by github_actions_runner Class)
#
# * user
# String, User to be used in Service and directories.(Default: Value set by github_actions_runner Class)
#
# * group
# String, Group to be used in Service and directories.(Default: Value set by github_actions_runner Class)
#
# * hostname
# String, actions runner name.
#
# * instance_name
# String, The instance name as part of the instances Hash.
#
# * repo_name
# Optional[String], actions runner repository name.
#
# * labels
# Optional[Array[String]], A list of costum lables to add to a runner.
#
# * runner_group
# Optional[String], The group to add this runner to if an org runner.
#

define github_actions_runner::instance (
  Enum['present', 'absent'] $ensure                = 'present',
  String                    $org_name              = $github_actions_runner::org_name,
  String                    $personal_access_token = $github_actions_runner::personal_access_token,
  String                    $user                  = $github_actions_runner::user,
  Optional[String]          $user_password         = $github_actions_runner::user_password,
  String                    $group                 = $github_actions_runner::group,
  String                    $hostname              = $::facts['hostname'],
  String                    $instance_name         = $title,
  Optional[Array[String]]   $labels                = undef,
  Optional[String]          $runner_group          = undef,
  Optional[String]          $repo_name             = undef,
  String                    $github_domain         = $github_actions_runner::github_domain,
  String                    $github_api            = $github_actions_runner::github_api,
) {

  if $labels {
    $flattend_labels_list=join($labels, ',')
    $assured_labels="--labels ${flattend_labels_list}"
  } else {
    $assured_labels = ''
  }

  if $runner_group {
    if $repo_name {
      warning("Ignoring runner_group ${runner_group} for repo specific instance ${org_name}/${repo_name}")
      $assured_runner_group=''
    } else {
      $assured_runner_group="--runnergroup \"${runner_group}\""
    }
  } else {
    $assured_runner_group=''
  }

  $url = $repo_name ? {
    undef => "${github_domain}/${org_name}",
    default => "${github_domain}/${org_name}/${repo_name}",
  }

  if $repo_name {
    $token_url = "${github_api}/repos/${org_name}/${repo_name}/actions/runners/registration-token"
  } else {
    $token_url = $github_api ? {
      'https://api.github.com' => "${github_api}/repos/${org_name}/actions/runners/registration-token",
      default => "${github_api}/orgs/${org_name}/actions/runners/registration-token",
    }
  }

  if $facts['os']['name'] == 'Windows' {
    $archive_name = "${github_actions_runner::package_name}-${github_actions_runner::package_ensure}.zip"
    $tmp_dir = "${github_actions_runner::root_dir}/${instance_name}-${archive_name}"
    $configure_script = 'ConfigureInstallRunner.ps1'
    $configure_script_permissions = '0775'
    $instance_directory_permissions = undef
  } elsif $facts['os']['name'] == 'Darwin' {
    $archive_name = "${github_actions_runner::package_name}-${github_actions_runner::package_ensure}.tar.gz"
    $tmp_dir = "/tmp/${instance_name}-${archive_name}"
    $configure_script = 'configure_install_runner_darwin.sh'
    $configure_script_permissions = '0755'
    $instance_directory_permissions = '0644'
  } else {
    $archive_name = "${github_actions_runner::package_name}-${github_actions_runner::package_ensure}.tar.gz"
    $tmp_dir = "/tmp/${instance_name}-${archive_name}"
    $configure_script = 'configure_install_runner.sh'
    $configure_script_permissions = '0755'
    $instance_directory_permissions = '0644'
  }

  $source = "${github_actions_runner::repository_url}/v${github_actions_runner::package_ensure}/${archive_name}"

  $ensure_instance_directory = $ensure ? {
    'present' => directory,
    'absent'  => absent,
  }

  $ensure_service = $ensure ? {
    'present' => running,
    'absent'  => stopped,
  }

  $enable_service = $ensure ? {
    'present' => true,
    'absent'  => false,
  }

  file { "${github_actions_runner::root_dir}/${instance_name}":
    ensure  => $ensure_instance_directory,
    mode    => $instance_directory_permissions,
    owner   => $user,
    group   => $group,
    force   => true,
    require => File[$github_actions_runner::root_dir],
  }

  archive { "${instance_name}-${archive_name}":
    ensure       => $ensure,
    path         => $tmp_dir,
    user         => $user,
    group        => $group,
    source       => $source,
    extract      => true,
    extract_path => "${github_actions_runner::root_dir}/${instance_name}",
    creates      => "${github_actions_runner::root_dir}/${instance_name}/bin",
    cleanup      => true,
    require      => File["${github_actions_runner::root_dir}/${instance_name}"],
  }

  file { "${github_actions_runner::root_dir}/${instance_name}/${configure_script}":
    ensure  => $ensure,
    mode    => $configure_script_permissions,
    owner   => $user,
    group   => $group,
    content => epp("github_actions_runner/${configure_script}.epp", {
      personal_access_token => $personal_access_token,
      token_url             => $token_url,
      instance_name         => $instance_name,
      root_dir              => $github_actions_runner::root_dir,
      url                   => $url,
      hostname              => $hostname,
      assured_labels        => $assured_labels,
      assured_runner_group  => $assured_runner_group,
      user                  => $user,
      user_password         => $user_password,
    }),
    notify  => Exec["${instance_name}-run_${configure_script}"],
    require => Archive["${instance_name}-${archive_name}"],
  }

  if $facts['os']['name'] == 'Windows' {
    exec { "fix ${github_actions_runner::root_dir}/${instance_name} permissions":
      cwd         => $github_actions_runner::root_dir,
      path        => $::path,
      command     => "icacls \".\\${instance_name}\" /grant:r \"${user}:(OI)(CI)F\" /grant:r \"${group}:(OI)(CI)F\"",
      refreshonly => true,
      subscribe   => File["${github_actions_runner::root_dir}/${instance_name}/${configure_script}"],
      notify      => Exec["${instance_name}-run_${configure_script}"],
    }

    exec { "${instance_name}-run_${configure_script}":
      cwd         => "${github_actions_runner::root_dir}/${instance_name}",
      path        => $::path,
      command     => "powershell -ExecutionPolicy RemoteSigned -File ${configure_script}",
      refreshonly => true,
    }

    service { "actions.runner._services.${hostname}-${instance_name}":
      ensure  => $ensure_service,
      enable  => $enable_service,
      require => Exec["${instance_name}-run_${configure_script}"]
    }
  } elsif $facts['os']['name'] == 'Darwin' {
    exec { "${instance_name}-run_${configure_script}":
      user        => $user,
      cwd         => "${github_actions_runner::root_dir}/${instance_name}",
      command     => "${github_actions_runner::root_dir}/${instance_name}/${configure_script}",
      refreshonly => true,
    }

    file { "${instance_name} launchd plist":
      path    => "/Library/LaunchDaemons/github-actions-runner.${instance_name}.plist",
      ensure  => file,
      content => epp('github_actions_runner/github-actions-runner.plist.epp', {
        instance_name => $instance_name,
        root_dir      => $github_actions_runner::root_dir,
        user          => $user,
      }),
      mode    => '0644',
      owner   => '0',
      group   => '0'
    }

    service { "github-actions-runner-${instance_name}":
      name    => "github-actions-runner-${instance_name}",
      ensure  => $ensure_service,
      enable  => $enable_service,
    }
  } else {
    exec { "${instance_name}-run_${configure_script}":
      user        => $user,
      cwd         => "${github_actions_runner::root_dir}/${instance_name}",
      command     => "${github_actions_runner::root_dir}/${instance_name}/${configure_script}",
      refreshonly => true,
    }

    systemd::unit_file { "github-actions-runner.${instance_name}.service":
      ensure  => $ensure,
      content => epp('github_actions_runner/github-actions-runner.service.epp', {
        instance_name => $instance_name,
        root_dir      => $github_actions_runner::root_dir,
        user          => $user,
        group         => $group,
      }),
      require => [File["${github_actions_runner::root_dir}/${instance_name}/${configure_script}"],
                  Exec["${instance_name}-run_${configure_script}"]],
      notify  => Service["github-actions-runner.${instance_name}.service"],
    }

    service { "github-actions-runner.${instance_name}.service":
      ensure  => $ensure_service,
      enable  => $enable_service,
      require => Class['systemd::systemctl::daemon_reload'],
    }
  }
}
