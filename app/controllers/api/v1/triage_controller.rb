# typed: strict
# frozen_string_literal: true

module Api
  module V1
    # What needs attention across the fleet (Triage): the ranked list for a
    # range, one finding worked up into evidence and a brief an agent can
    # act on, and a person's answer to one — dismissed until it gets worse,
    # or ignored for good.
    class TriageController < BaseController
      # GET /api/v1/triage?from&to&app
      sig { void }
      def index
        app = params[:app].presence&.to_s&.downcase
        return render_errors("“app” is an app's slug") unless app.nil? || app.match?(App::SLUG_FORMAT)

        window = window_param
        report = Triage.report(current_household!, window: window, app: app)
        render json: TriageSerializer.report_json(report, window)
      end

      # GET /api/v1/triage/:id?from&to
      sig { void }
      def show
        subject = Triage::Subject.parse(params[:id].to_s)
        return render_not_found if subject.nil?

        window = window_param
        detail = Triage.detail(current_household!, window: window, subject: subject)
        return render_no_longer if detail.nil?

        render json: TriageSerializer.detail_json(detail, window, dismissal: current_household!.triage_dismissals.find_by(finding_id: subject.id))
      end

      # PUT /api/v1/triage/:id/dismissal { mode, from, to } — the range is
      # the one the finding was seen over: how bad it was there is what
      # "worse" will be measured against.
      sig { void }
      def dismiss
        subject = Triage::Subject.parse(params[:id].to_s)
        return render_not_found if subject.nil?

        mode = TriageDismissal::Mode.try_deserialize(params[:mode].to_s)
        return render_errors("“mode” is dismissed or ignored") if mode.nil?

        window = window_param
        finding = Triage.find(current_household!, window: window, subject: subject)
        return render_no_longer if finding.nil?

        dismissal = TriageDismissal.record!(current_household!, finding, mode: mode, user: current_user!)
        render json: TriageSerializer.dismissal_json(dismissal)
      end

      # DELETE /api/v1/triage/:id/dismissal — back in the list.
      sig { void }
      def restore
        current_household!.triage_dismissals.find_by!(finding_id: params[:id].to_s).destroy!
        head :no_content
      end

      private

      sig { void }
      def render_no_longer
        render_errors("It no longer stands out over this range — fixed, quiet, or outside it", status: :not_found)
      end

      # Both bounds are required; Triage::Window keeps the range to what it
      # can triage.
      sig { returns(Triage::Window) }
      def window_param
        from, to = range_param(default: nil)
        Triage::Window.around(from: from, to: to)
      end
    end
  end
end
