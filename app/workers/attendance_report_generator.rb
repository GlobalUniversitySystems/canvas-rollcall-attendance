#
# Copyright (C) 2014 - present Instructure, Inc.
#
# This file is part of Rollcall.
#
# Rollcall is free software: you can redistribute it and/or modify it under
# the terms of the GNU Affero General Public License as published by the Free
# Software Foundation, version 3 of the License.
#
# Rollcall is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE. See the GNU Affero General Public License for more
# details.
#
# You should have received a copy of the GNU Affero General Public License along
# with this program. If not, see <http://www.gnu.org/licenses/>.

class AttendanceReportGenerator
  extend ResqueStats

  @queue = :attendance_reports

  AUTHENTICATION_ATTEMPTS = 3
  AUTHENTICATION_RETRY_DELAY = 5

  def self.perform(params)
    params = params.with_indifferent_access

    check_params!(params)

    url = nil
    message = nil

    begin
      report = build_report_with_authentication_retry(params)

      csv_string = report.to_csv
      filename = "attendance-#{SecureRandom.uuid}.csv"
      url = AttendanceReportUploader.s3_url(filename, csv_string)
    rescue AttendanceReport::SisFilterNotFound => e
      message = e.message
    rescue => e
      Rails.logger.error(
        "Attendance report generation failed: " \
          "#{e.class.name} - #{e.message}\n" \
          "#{e.backtrace&.first(30)&.join("\n")}"
      )

      notify_user_of_error(params[:email])
      raise
    end

    ReportMailer.attendance_report(params[:email], url, message).deliver_now
    EmailLog.create(
      to: params[:email],
      subject: "attendance_report",
      body: "url: #{url}, message: #{message}",
      sent_at: Time.current
    )
  end

  def self.build_report_with_authentication_retry(params)
    attempts = 0

    begin
      attempts += 1

      canvas = CanvasOauth::CanvasApiExtensions.build(
        params[:canvas_url],
        params[:user_id],
        params[:tool_consumer_instance_guid]
      )

      AttendanceReport.new(canvas, params)
    rescue CanvasOauth::CanvasApi::Authenticate => e
      Rails.logger.warn(
        "Canvas authentication failed " \
          "attempt=#{attempts}/#{AUTHENTICATION_ATTEMPTS} " \
          "user_id=#{params[:user_id]} " \
          "course_id=#{params[:course_id]} " \
          "canvas_url=#{params[:canvas_url]}"
      )

      raise if attempts >= AUTHENTICATION_ATTEMPTS

      sleep AUTHENTICATION_RETRY_DELAY
      retry
    end
  end

  def self.check_params!(params)
    required = [:user_id, :canvas_url, :email]
    required.each do |key|
      if params[key].blank?
        notify_user_of_error(params[:email])
        raise "Required field #{key} is blank - unable to generate Attendance Report"
      end
    end
  end

  def self.notify_user_of_error(email)
    unless email.blank?
      error_message = "There was a problem generating your report. We have been notified of this issue and apologize for the inconvenience."
      ReportMailer.attendance_report(email, nil, error_message).deliver_now
    end
  end
end
