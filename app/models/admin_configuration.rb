class AdminConfiguration

  ###
  #
  # AdminConfiguration: a generic object that is used to hold site-wide configuration options
  # Can only be accessed by user accounts that are configured as 'admins'
  #
  ###

  include Mongoid::Document
  field :config_type, type: String
  field :value_type, type: String
  field :multiplier, type: String
  field :value, type: String

  has_many :configuration_options, dependent: :destroy
  accepts_nested_attributes_for :configuration_options, allow_destroy: true

  validates_uniqueness_of :config_type,
                          message: ": '%{value}' has already been set.  Please edit the corresponding entry to update.",
                          unless: proc {|attributes| attributes['config_type'] == 'Workflow Name'}

  validate :validate_value_by_type

  FIRECLOUD_ACCESS_NAME = 'FireCloud Access'
  API_NOTIFIER_NAME = 'API Health Check Notifier'
  NUMERIC_VALS = %w(byte kilobyte megabyte terabyte petabyte exabyte)

  # really only used for IDs in the table...
  def url_safe_name
    self.config_type.downcase.gsub(/[^a-zA-Z0-9]+/, '-').chomp('-')
  end

  def self.config_types
    ['Daily User Download Quota', 'Workflow Name', 'Portal FireCloud User Group', 'Reference Data Workspace', API_NOTIFIER_NAME]
  end

  def self.value_types
    ['Numeric', 'Boolean', 'String']
  end

  def self.current_firecloud_access
    status = AdminConfiguration.find_by(config_type: AdminConfiguration::FIRECLOUD_ACCESS_NAME)
    if status.nil?
      'on'
    else
      status.value
    end
  end

  def self.firecloud_access_enabled?
    status = AdminConfiguration.find_by(config_type: AdminConfiguration::FIRECLOUD_ACCESS_NAME)
    if status.nil?
      true
    else
      status.value == 'on'
    end
  end

  # display value formatted by type
  def display_value
    case self.value_type
      when 'Numeric'
        unless self.multiplier.nil? || self.multiplier.blank?
          "#{self.value} #{self.multiplier}(s) <span class='badge'>#{self.convert_value_by_type} bytes</span>"
        else
          self.value
        end
      when 'Boolean'
        self.value == '1' ? 'Yes' : 'No'
      else
        self.value
    end
  end

  # converter to return requested value as an instance of its value type
  # numerics will return an interger or float depending on value contents (also understands Rails shorthands for byte size increments)
  # booleans return true/false based on matching a variety of possible 'true' values
  # strings just return themselves
  def convert_value_by_type
    case self.value_type
      when 'Numeric'
        unless self.multiplier.nil? || self.multiplier.blank?
          val = self.value.include?('.') ? self.value.to_f : self.value.to_i
          return val.send(self.multiplier.to_sym)
        else
          return self.value.to_f
        end
      when 'Boolean'
        return self.value == '1'
      else
        return self.value
    end
  end

  # method that disables access by revoking permissions to studies directly in FireCloud
  def self.configure_firecloud_access(status)
    case status
      when 'readonly'
        @config_setting = 'READER'
      when 'off'
        @config_setting = 'NO ACCESS'
      else
        @config_setting = 'ERROR'
    end
    unless @config_setting == 'ERROR'
      Rails.logger.info "#{Time.now}: setting access on all '#{FireCloudClient::COMPUTE_BLACKLIST.join(', ')}' studies to #{@config_setting}"
      # only use studies not queued for deletion; those have already had access revoked
      # also filter out studies not in default portal project - user-funded projects are exempt from access revocation
      Study.not_in(queued_for_deletion: true).where(:firecloud_project.in => FireCloudClient::COMPUTE_BLACKLIST).each do |study|
        Rails.logger.info "#{Time.now}: begin revoking access to study: #{study.name}"
        # first remove share access (only shares with FireCloud access, i.e. non-reviewers)
        shares = study.study_shares.non_reviewers
        shares.each do |user|
          Rails.logger.info "#{Time.now}: revoking share access for #{user}"
          revoke_share_acl = Study.firecloud_client.create_workspace_acl(user, @config_setting)
          Study.firecloud_client.update_workspace_acl(study.firecloud_project, study.firecloud_workspace, revoke_share_acl)
        end
        # last, remove study owner access (unless project owner)
        owner = study.user.email
        Rails.logger.info "#{Time.now}: revoking owner access for #{owner}"
        revoke_owner_acl = Study.firecloud_client.create_workspace_acl(owner, @config_setting)
        Study.firecloud_client.update_workspace_acl(study.firecloud_project, study.firecloud_workspace, revoke_owner_acl)
        Rails.logger.info "#{Time.now}: access revocation for #{study.name} complete"
      end
      Rails.logger.info "#{Time.now}: all '#{FireCloudClient::COMPUTE_BLACKLIST.join(', ')}' study access set to #{@config_setting}"
    else
      Rails.logger.info "#{Time.now}: invalid status setting: #{status}; aborting"
    end
  end

  # method that re-enables access by restoring permissions to studies directly in FireCloud
  def self.enable_firecloud_access
    Rails.logger.info "#{Time.now}: restoring access to all '#{FireCloudClient::COMPUTE_BLACKLIST.join(', ')}' studies"
    # only use studies not queued for deletion; those have already had access revoked
    # also filter out studies not in default portal project - user-funded projects are exempt from access revocation
    Study.not_in(queued_for_deletion: true).where(:firecloud_project.in => FireCloudClient::COMPUTE_BLACKLIST).each do |study|
      Rails.logger.info "#{Time.now}: begin restoring access to study: #{study.name}"
      # first re-enable share access (to all non-reviewers)
      shares = study.study_shares.where(:permission.nin => %w(Reviewer)).to_a
      shares.each do |share|
        user = share.email
        share_permission = StudyShare::FIRECLOUD_ACL_MAP[share.permission]
        can_share = share_permission === 'WRITER' ? true : false
        can_compute = Rails.env == 'production' ? false : share_permission === 'WRITER' ? true : false
        Rails.logger.info "#{Time.now}: restoring #{share_permission} permission for #{user}"
        restore_share_acl = Study.firecloud_client.create_workspace_acl(user, share_permission, can_share, can_compute)
        Study.firecloud_client.update_workspace_acl(study.firecloud_project, study.firecloud_workspace, restore_share_acl)
      end
      # last, restore study owner access (unless project is owned by user)
      owner = study.user.email
      Rails.logger.info "#{Time.now}: restoring WRITER access for #{owner}"
      # restore permissions, setting compute acls correctly (disabled in production for COMPUTE_BLACKLIST projects)
      restore_owner_acl = Study.firecloud_client.create_workspace_acl(owner, 'WRITER', true, Rails.env == 'production' ? false : true)
      Study.firecloud_client.update_workspace_acl(study.firecloud_project, study.firecloud_workspace, restore_owner_acl)
      Rails.logger.info "#{Time.now}: access restoration for #{study.name} complete"
    end
    Rails.logger.info "#{Time.now}: all '#{FireCloudClient::COMPUTE_BLACKLIST.join(', ')}' study access restored"
  end

  # sends an email to all site administrators on startup notifying them of portal restart
  def self.restart_notification
    current_time = Time.now.to_s(:long)
    locked_jobs = Delayed::Job.where(:locked_by.nin => [nil]).count
    message = "<p>The Single Cell Portal was restarted at #{current_time}.</p><p>There are currently #{locked_jobs} jobs waiting to be restarted.</p>"
    SingleCellMailer.admin_notification('Portal restart', nil, message).deliver_now
  end

  # method to unlock all current delayed_jobs to allow them to be restarted
  def self.restart_locked_jobs
    # determine current processes and their pids
    job_count = 0
    pid_files = Dir.entries(Rails.root.join('tmp','pids')).delete_if {|p| p.start_with?('.')}
    pids = {}
    pid_files.each do |file|
      pids[file.chomp('.pid')] = File.open(Rails.root.join('tmp', 'pids', file)).read.strip
    end
    locked_jobs = Delayed::Job.where(:locked_by.nin => [nil]).to_a
    locked_jobs.each do |job|
      # grab worker number and pid
      worker, pid_str = job.locked_by.split.minmax
      pid = pid_str.split(':').last
      # check if current job worker has matching pid; if not, then the job is orphaned and should be unlocked
      unless pids[worker] == pid
        # deserialize handler object to get attributes for logging
        deserialized_handler = YAML::load(job.handler)
        job_method = deserialized_handler.method_name.to_s
        Rails.logger.info "#{Time.now}: Restarting orphaned process #{job.id}:#{job_method} initially queued on #{job.created_at.to_s(:long)}"
        job.update(locked_by: nil, locked_at: nil)
        job_count += 1
      end
    end
    job_count
  end

  # method to be called from cron to check the health status of the FireCloud API and set access if an outage is detected
  def self.check_api_health
    notifier_config = AdminConfiguration.find_or_create_by(config_type: AdminConfiguration::API_NOTIFIER_NAME, value_type: 'Boolean')
    firecloud_access = AdminConfiguration.find_or_create_by(config_type: AdminConfiguration::FIRECLOUD_ACCESS_NAME, value_type: 'String')
    api_available = Study.firecloud_client.api_available?

    # gotcha for very first time this is ever called
    if firecloud_access.value.nil?
      firecloud_access.update(value: 'on')
    end

    if notifier_config.value.nil?
      notifier_config.update(value: 1)
    end

    # if api is down...
    if !api_available
      # if access is still enabled, set to local-off and send notification to admins (if enabled)
      if firecloud_access.value == 'on'
        Rails.logger.error "#{Time.now}: ALERT: FIRECLOUD API UNAVAILABLE -- setting FireCloud access to 'local-off'"
        firecloud_access.update(value: 'local-off')
        if notifier_config.value == '1'
          current_time = Time.now.strftime('%D %r')
          SingleCellMailer.admin_notification('ALERT: FIRECLOUD API UNAVAILABLE', nil, "<p>The FireCloud API was found to be unavailable at #{current_time}.  Access has been disabled locally until API access is manually turned back on or the next automatic check returns positive.").deliver_now
          notifier_config.update(value: '0')
        end
      end
    # if api is up...
    else
      if firecloud_access.value == 'local-off'
        # local-off is currently used exclusively for API outages, so if the API is up and the portal is set to local-off,
        # then we can assume that the portal was put in this mode by AdminConfiguration.check_api_health and should
        # automatically recover.  This will not affect disabling compute or all access settings.
        firecloud_access.update(value: 'on')
        if notifier_config.value == '0'
          current_time = Time.now.strftime('%D %r')
          SingleCellMailer.admin_notification('ALERT: FireCloud API recovery', nil, "<p>The FireCloud API has recovered as of #{current_time}.  Access has been automatically restored.").deliver_now
          notifier_config.update(value: '1')
        end
      end
    end
  end

  # getter to return all configuration options as a hash
  def options
    opts = {}
    self.configuration_options.each do |option|
      opts.merge!({option.name.to_sym => option.value})
    end
    opts
  end

  private

  def validate_value_by_type
    case self.value_type
      when 'Numeric'
        unless self.value.to_f >= 0
          errors.add(:value, 'must be greater than or equal to zero.  Please enter another value.')
        end
      else
        # for booleans, we use a select box so values are constrained.  for strings, any value is valid
        return true
    end
  end
end

