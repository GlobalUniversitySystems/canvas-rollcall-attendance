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

class StatusesController < ApplicationController
  API_TOKEN = ENV.fetch('ROLLCALL_STATUSES_API_TOKEN')

  skip_before_action :request_canvas_authentication, :only => [:fetch_for_course, :fetch_recent]
  skip_before_action :require_lti_launch, :only => [:fetch_for_course, :fetch_recent]

  before_action :can_grade, except: [:fetch_for_course, :fetch_recent]

  respond_to :json

  def index
    if section = load_and_authorize_full_section(params[:section_id])
      statuses = Status.initialize_list(
        section,
        params[:class_date],
        user_id,
        tool_consumer_instance_guid
      )
      respond_with statuses
    else
      not_acceptable
    end
  end

  def fetch_for_course
    course_id = params[:course_id]
    api_token = params[:api_token]

    if api_token != API_TOKEN
      render json: "You do not have permissions."
    elsif !Status.exists?(course_id: course_id)
      render json: "Invalid course id."
    else
      render json: Status.where(course_id: course_id).to_json
    end
  end

  def fetch_recent
    api_token = params[:api_token]
    date = Date.parse(params[:date])

    if api_token != API_TOKEN
      render json: "You do not have permissions."
    elsif date.blank?
      render json: "Please provide start date."
    else
      render json: Status.where("updated_at >= ?", date).to_json
    end
  end

  def create
    course_id = params[:status][:course_id]
    if course = load_and_authorize_course(course_id)
      #This makes sure that the Status is unique for the student and
      #the corresponding course.
      status = Status.where(
        student_id: params[:status][:student_id],
        section_id: params[:status][:section_id],
        class_date: params[:status][:class_date],
        course_id: params[:status][:course_id],
        tool_consumer_instance_guid: tool_consumer_instance_guid
      ).first

      status ||= Status.new(status_params)
      status.assign_attributes(
        course_id: course.id,
        account_id: course.account_id
      )

      begin
        submit_grade!(status) if status.save
      rescue ActiveRecord::RecordNotUnique
        # duplicate record - can happen with competing requests to the server
      end
      render_status(status)
    else
      not_acceptable
    end
  end

  def update
    if status = Status.find_by(id: params[:id])
      if load_and_authorize_section(status.section_id)
        status.attendance = status_params[:attendance]
        status.teacher_id = user_id
        submit_grade!(status) if status.save
        render_status(status)
      else
        not_acceptable
      end
    else
      head :not_found
    end
  end

  def destroy
    if status = Status.find_by(id: params[:id])
      if load_and_authorize_section(status.section_id)
        submit_grade!(status) if status.destroy
        render_status(status)
      else
        not_acceptable
      end
    else
      head :not_found
    end
  end

  protected
  def submit_grade!(status)
    grade_params = {
      canvas_url: canvas_url,
      user_id: user_id,
      student_id: status.student_id,
      section_id: status.section_id,
      course_id: status.course_id,
      tool_consumer_instance_guid: status.tool_consumer_instance_guid,
      identifier: SecureRandom.hex(32),
      tool_launch_url: launch_url
    }

    Resque.enqueue(GradeUpdater, grade_params)
  end

  def render_status(status)
    respond_to do |format|
      format.json { render json: status.as_json }
    end
  end

  private
  def status_params
    params.require(:status).permit(:class_date, :attendance, :section_id, :student_id, :course_id).merge({
      tool_consumer_instance_guid: tool_consumer_instance_guid,
      teacher_id: user_id,
      fixed: true
    })
  end
end
