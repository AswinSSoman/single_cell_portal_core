class ApplicationController < ActionController::Base

  ###
  #
  # These are methods that are not specific to any one controller and are inherited into all
  # They are all either access control filters or instance variable setters
  #
  ###


  # Prevent CSRF attacks by raising an exception.
  # For APIs, you may want to use :null_session instead.
  protect_from_forgery with: :exception

  before_action :get_download_quota
  before_action :set_selected_branding_group

  # auth action for portal admins
  def authenticate_admin
    unless current_user.admin?
      redirect_to merge_default_redirect_params(site_path, scpbr: params[:scpbr]), alert: 'You do not have permission to access that page.' and return
    end
  end

  # auth action for portal reporters
  def authenticate_reporter
    unless current_user.acts_like_reporter?
      redirect_to merge_default_redirect_params(site_path, scpbr: params[:scpbr]), alert: 'You do not have permission to access that page.' and return
    end
  end

  # retrieve the current download quota
  def get_download_quota
    config_entry = AdminConfiguration.find_by(config_type: 'Daily User Download Quota')
    if config_entry.nil? || config_entry.value_type != 'Numeric'
      # fallback in case entry cannot be found or is set to wrong type
      @download_quota = 2.terabytes
    else
      @download_quota = config_entry.convert_value_by_type
    end
  end

  # check whether downloads/study editing has been revoked and prevent user access
  def check_access_settings
    redirect = request.referrer.nil? ? site_path : request.referrer
    downloads_enabled = AdminConfiguration.firecloud_access_enabled?
    if !downloads_enabled
      redirect_to merge_default_redirect_params(redirect, scpbr: params[:scpbr]), alert: "Study access has been temporarily disabled by the site adminsitrator.  Please contact #{view_context.mail_to('single_cell_portal@broadinstitute.org')} if you require assistance." and return
    end
  end

  # load default study options for updating
  def set_study_default_options
    @default_cluster = @study.default_cluster
    @default_cluster_annotations = {
        'Study Wide' => @study.cell_metadata.map {|metadata| ["#{metadata.name}", "#{metadata.name}--#{metadata.annotation_type}--study"] }.uniq
    }
    unless @default_cluster.nil?
      @default_cluster_annotations['Cluster-based'] = @default_cluster.cell_annotations.map {|annot| ["#{annot[:name]}", "#{annot[:name]}--#{annot[:type]}--cluster"]}
    end
  end

  # rescue from an invalid csrf token (if user logged out in another window)
  def session_expired
    @alert = 'Your session has expired.  Please log in again to continue.'
    respond_to do |format|
      format.html {redirect_to merge_default_redirect_params(site_path, scpbr: params[:scpbr]), alert: @alert}
      format.js {render template: '/layouts/session_expired'}
      format.json {head 403}
    end
  end

  # set branding group if present
  def set_selected_branding_group
    if params[:scpbr].present?
      @selected_branding_group = BrandingGroup.find_by(name_as_id: params[:scpbr])
    end
  end

  # merge in extra parameters on redirects as necessary
  def merge_default_redirect_params(redirect_route, extra_params={})
    merged_redirect_url = redirect_route.dup
    extra_params.each do |key, value|
      if value.present?
        if redirect_route.include?('?')
          merged_redirect_url += "&#{key}=#{value}"
        else
          merged_redirect_url += "?#{key}=#{value}"
        end
      end
    end
    merged_redirect_url
  end
end
