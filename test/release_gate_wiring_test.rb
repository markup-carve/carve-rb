# frozen_string_literal: true

# The release gate has to be REACHED, and the push has to be UNREACHABLE past
# it.
#
# scripts/verify-release-artifact.sh can be correct and still guard nothing.
# Three ways, all of them observed in this org rather than imagined:
#
#   - it runs, diverges, and the workflow keeps going, because the divergence is
#     reported instead of returned. laravel-carve, symfony-carve and
#     shopware-carve each carry a correct comparison over the full corpus that
#     exits 0 and leaves every required check green while the engine they ship
#     renders a sixth of the spec differently;
#   - it runs in the same job as the push, above it. Step order reads like a
#     gate and is not one: it survives a `continue-on-error:`, and it puts the
#     credentials into the same job as the check that is supposed to decide
#     whether they get used;
#   - it stops running at all, because the step was renamed, moved, or the
#     workflow was rewritten around it, and nothing notices until a release.
#
# So this file asserts the shape rather than the behavior: the publish job is a
# separate job, it `needs:` the verifying job, it pushes an artifact it did not
# build, and the gate script is invoked by both this repository's workflows.
# None of that can be checked by running the release, because a release cannot
# be run twice.

require "minitest/autorun"
require "yaml"

class ReleaseGateWiringTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  GATE = "scripts/verify-release-artifact.sh"

  def release
    @release ||= YAML.safe_load_file(File.join(ROOT, ".github/workflows/release.yml"), aliases: true)
  end

  def ci
    @ci ||= YAML.safe_load_file(File.join(ROOT, ".github/workflows/ci.yml"), aliases: true)
  end

  def steps_of(workflow, job)
    workflow.fetch("jobs").fetch(job).fetch("steps")
  end

  def run_lines(workflow, job)
    steps_of(workflow, job).filter_map { |step| step["run"] }.join("\n")
  end

  def test_the_release_workflow_verifies_the_gem_it_built
    assert release.fetch("jobs").key?("verify"),
           "release.yml has no `verify` job. jobs: #{release.fetch('jobs').keys.inspect}"
    assert_includes run_lines(release, "verify"), GATE,
                    "the release workflow's verify job never runs #{GATE}, so nothing asks " \
                    "whether the gem it is about to publish renders the spec corpus correctly."
  end

  def test_the_publish_job_cannot_start_unless_the_gate_passed
    publish = release.fetch("jobs").fetch("publish")
    needs = Array(publish["needs"])
    assert_includes needs, "verify",
                    "the publish job does not `needs: verify`. Without it the push is ordered " \
                    "after the gate at best, and ordering is not a gate: the point of the " \
                    "dependency is that a failing gate makes the push unreachable rather than " \
                    "merely later."
  end

  # The gate proves something about a specific file. If publish builds its own
  # gem, the file it pushes is a second build that nothing looked at -- same
  # source, but not the artifact anyone verified, and a native gem's contents
  # are not a pure function of its source tree.
  def test_the_publish_job_pushes_the_artifact_it_did_not_build
    runs = run_lines(release, "publish")
    refute_includes runs, "gem build",
                    "the publish job builds its own gem. It has to push the artifact the " \
                    "verify job uploaded, or the bytes that were verified and the bytes that " \
                    "are served are two different things."
    assert_includes runs, "gem push",
                    "the publish job does not push anything; this test is asserting against " \
                    "the wrong job."

    uses = steps_of(release, "publish").filter_map { |step| step["uses"] }.join("\n")
    assert_includes uses, "actions/download-artifact",
                    "the publish job does not download the verified gem, so whatever it pushes " \
                    "did not come from the job that checked it."
  end

  # A gate that only fires on a tag is a gate nobody has watched work. It rots
  # quietly between releases and the run that finds it broken is the run with a
  # version waiting to go out.
  def test_the_same_gate_runs_on_every_push
    assert_includes run_lines(ci, "build"), GATE,
                    "ci.yml never runs #{GATE}. The release-only copy would then first be " \
                    "exercised during a release, which is the worst moment to learn it does " \
                    "not work."
  end

  def test_the_gate_script_is_executable_and_present
    path = File.join(ROOT, GATE)
    assert File.exist?(path), "#{GATE} is missing but both workflows invoke it"
    assert File.exist?(File.join(ROOT, "scripts/verify-packaged-gem.rb")),
           "scripts/verify-packaged-gem.rb is missing; #{GATE} is only its driver"
  end
end
