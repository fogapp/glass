# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe ManagedJob do
  let(:job_class) do
    Class.new(ApplicationJob) do
      include ManagedJob

      const_set(:JOB_KEY, "managed_job_spec")

      def run_job = "ran as #{job_run.id}"
    end
  end

  it "runs the body inside the run the trigger created, handing it that run" do
    claim = JobRun.claim(job_key: "managed_job_spec", stale_after: 15.minutes, trigger: JobRun::Trigger::Manual)
    job_class.new.perform(claim.job_run.id)

    run = claim.job_run.reload
    expect(run.finished_at).to be_present
    expect(run.message).to eq("ran as #{run.id}")
  end

  it "makes a run of its own when performed without one" do
    expect { job_class.new.perform }.to change { JobRun.where(job_key: "managed_job_spec").count }.by(1)
  end
end
