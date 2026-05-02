defmodule SymphonyElixir.GitHubClientTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.GitHub.Client

  setup do
    previous_runner = Application.get_env(:symphony_elixir, :github_gh_runner)

    on_exit(fn ->
      if is_nil(previous_runner) do
        Application.delete_env(:symphony_elixir, :github_gh_runner)
      else
        Application.put_env(:symphony_elixir, :github_gh_runner, previous_runner)
      end
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_api_token: nil,
      tracker_project_slug: nil,
      tracker_repository: "owner/repo",
      tracker_status_labels: %{
        todo: "Symphony:Todo",
        in_progress: "Symphony:In-Progress",
        rework: "Symphony:Rework",
        human_review: "Symphony:Human-Review",
        blocked: "Symphony:Blocked"
      },
      tracker_active_states: ["Todo", "In Progress", "Rework"],
      tracker_terminal_states: ["Closed", "Done"]
    )

    :ok
  end

  test "normalizes GitHub issue payloads into Symphony issue records" do
    tracker = Config.settings!().tracker

    issue =
      Client.normalize_issue_for_test(
        %{
          "number" => 27,
          "title" => "COM-10/SYM-03: Request upstream adapter",
          "body" => "body",
          "state" => "OPEN",
          "url" => "https://github.com/owner/repo/issues/27",
          "labels" => [
            %{"name" => "Symphony"},
            %{"name" => "Symphony:In-Progress"}
          ],
          "createdAt" => "2026-05-02T08:00:00Z",
          "updatedAt" => "2026-05-02T09:00:00Z"
        },
        tracker,
        "owner/repo"
      )

    assert issue.id == "github:owner/repo#27"
    assert issue.identifier == "GH-27"
    assert issue.state == "In Progress"
    assert issue.labels == ["symphony", "symphony:in-progress"]
    assert issue.created_at == ~U[2026-05-02 08:00:00Z]
    assert issue.updated_at == ~U[2026-05-02 09:00:00Z]
  end

  test "closed GitHub issues normalize to terminal states" do
    tracker = Config.settings!().tracker

    done_issue =
      Client.normalize_issue_for_test(
        %{"number" => 1, "state" => "CLOSED", "stateReason" => "COMPLETED", "labels" => []},
        tracker,
        "owner/repo"
      )

    closed_issue =
      Client.normalize_issue_for_test(
        %{"number" => 2, "state" => "CLOSED", "stateReason" => "NOT_PLANNED", "labels" => []},
        tracker,
        "owner/repo"
      )

    assert done_issue.state == "Done"
    assert closed_issue.state == "Closed"
  end

  test "fetch_candidate_issues shells out to gh and filters active states" do
    Application.put_env(:symphony_elixir, :github_gh_runner, fn args ->
      send(self(), {:gh_called, args})

      {:ok,
       Jason.encode!([
         %{
           "number" => 1,
           "title" => "ready",
           "state" => "OPEN",
           "labels" => [%{"name" => "symphony"}, %{"name" => "symphony:todo"}]
         },
         %{
           "number" => 2,
           "title" => "review",
           "state" => "OPEN",
           "labels" => [%{"name" => "symphony"}, %{"name" => "symphony:human-review"}]
         }
       ])}
    end)

    assert {:ok, [issue]} = Client.fetch_candidate_issues()
    assert issue.identifier == "GH-1"

    assert_receive {:gh_called,
                    [
                      "issue",
                      "list",
                      "--repo",
                      "owner/repo",
                      "--state",
                      "open",
                      "--label",
                      "symphony",
                      "--limit",
                      "100",
                      "--json",
                      _fields
                    ]}
  end

  test "fetch_issues_by_states combines open status labels and closed terminal states" do
    Application.put_env(:symphony_elixir, :github_gh_runner, fn args ->
      send(self(), {:gh_called, args})

      case args do
        [
          "issue",
          "list",
          "--repo",
          "owner/repo",
          "--state",
          "open",
          "--label",
          "symphony",
          "--limit",
          "100",
          "--json",
          _fields
        ] ->
          {:ok,
           Jason.encode!([
             %{
               "number" => 1,
               "title" => "todo",
               "state" => "OPEN",
               "labels" => [%{"name" => "symphony"}, %{"name" => "symphony:todo"}]
             },
             %{
               "number" => 2,
               "title" => "review",
               "state" => "OPEN",
               "labels" => [%{"name" => "symphony"}, %{"name" => "symphony:human-review"}]
             }
           ])}

        [
          "issue",
          "list",
          "--repo",
          "owner/repo",
          "--state",
          "closed",
          "--limit",
          "100",
          "--json",
          _fields
        ] ->
          {:ok,
           Jason.encode!([
             %{"number" => 3, "title" => "done", "state" => "CLOSED", "stateReason" => "COMPLETED"},
             %{"number" => 4, "title" => "closed", "state" => "CLOSED", "stateReason" => "NOT_PLANNED"}
           ])}

        other ->
          {:error, {:unexpected_gh_args, other}}
      end
    end)

    assert {:ok, issues} = Client.fetch_issues_by_states(["Todo", "Done"])
    assert Enum.map(issues, & &1.identifier) == ["GH-1", "GH-3"]

    assert_receive {:gh_called, ["issue", "list", "--repo", "owner/repo", "--state", "open", "--label", "symphony" | _rest]}
    assert_receive {:gh_called, ["issue", "list", "--repo", "owner/repo", "--state", "closed" | _rest]}
  end

  test "update_issue_state uses gh labels instead of raw GraphQL" do
    Application.put_env(:symphony_elixir, :github_gh_runner, fn args ->
      send(self(), {:gh_called, args})

      case args do
        ["issue", "view", "27", "--repo", "owner/repo", "--json", _fields] ->
          {:ok,
           Jason.encode!(%{
             "number" => 27,
             "state" => "OPEN",
             "labels" => [
               %{"name" => "symphony"},
               %{"name" => "symphony:todo"}
             ]
           })}

        [
          "issue",
          "edit",
          "27",
          "--repo",
          "owner/repo",
          "--add-label",
          "Symphony:In-Progress",
          "--remove-label",
          "symphony:todo"
        ] ->
          {:ok, ""}

        other ->
          {:error, {:unexpected_gh_args, other}}
      end
    end)

    assert :ok = Client.update_issue_state("github:owner/repo#27", "In Progress")

    assert_receive {:gh_called, ["issue", "view", "27", "--repo", "owner/repo", "--json", _fields]}

    assert_receive {:gh_called,
                    [
                      "issue",
                      "edit",
                      "27",
                      "--repo",
                      "owner/repo",
                      "--add-label",
                      "Symphony:In-Progress",
                      "--remove-label",
                      "symphony:todo"
                    ]}
  end

  test "issue references accept stable GitHub ids and friendly keys" do
    assert {:ok, "27"} = Client.issue_reference_for_test("github:owner/repo#27")
    assert {:ok, "27"} = Client.issue_reference_for_test("GH-27")
    assert {:ok, "27"} = Client.issue_reference_for_test("#27")
    assert {:ok, "27"} = Client.issue_reference_for_test("27")
    assert {:error, {:unsupported_github_issue_id, "node-id"}} = Client.issue_reference_for_test("node-id")
  end
end
