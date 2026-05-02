defmodule SymphonyElixir.GitHub.Client do
  @moduledoc """
  GitHub Issues client backed by the authenticated `gh` CLI.
  """

  require Logger

  alias SymphonyElixir.{Config, Linear.Issue}

  @issue_fields "number,title,state,stateReason,labels,body,url,createdAt,updatedAt,id"
  @issue_limit 100

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    tracker = Config.settings!().tracker

    with {:ok, repository} <- repository(tracker),
         {:ok, issues} <-
           gh_json([
             "issue",
             "list",
             "--repo",
             repository,
             "--state",
             "open",
             "--label",
             tracker.dispatch_label,
             "--limit",
             Integer.to_string(@issue_limit),
             "--json",
             @issue_fields
           ]) do
      active_states = MapSet.new(tracker.active_states)

      normalized =
        issues
        |> Enum.map(&normalize_issue(&1, tracker, repository))
        |> Enum.filter(&match?(%Issue{}, &1))
        |> Enum.filter(&MapSet.member?(active_states, &1.state))

      {:ok, normalized}
    end
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) when is_list(state_names) do
    normalized_states =
      state_names
      |> Enum.map(&to_string/1)
      |> Enum.reject(&(String.trim(&1) == ""))
      |> Enum.uniq()

    if normalized_states == [] do
      {:ok, []}
    else
      tracker = Config.settings!().tracker
      {terminal_states, active_states} = Enum.split_with(normalized_states, &terminal_state?(&1, tracker.terminal_states))

      with {:ok, active_issues} <- fetch_open_issues_by_states(active_states),
           {:ok, terminal_issues} <- fetch_closed_issues(terminal_states) do
        {:ok, active_issues ++ terminal_issues}
      end
    end
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) when is_list(issue_ids) do
    tracker = Config.settings!().tracker

    with {:ok, repository} <- repository(tracker) do
      issue_ids
      |> Enum.uniq()
      |> Enum.reduce_while({:ok, []}, fn issue_id, {:ok, acc} ->
        case fetch_issue_by_id(issue_id, tracker, repository) do
          {:ok, %Issue{} = issue} -> {:cont, {:ok, [issue | acc]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, issues} -> {:ok, Enum.reverse(issues)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    tracker = Config.settings!().tracker

    with {:ok, repository} <- repository(tracker),
         {:ok, issue_ref} <- issue_reference(issue_id),
         {:ok, _output} <- gh(["issue", "comment", issue_ref, "--repo", repository, "--body", body]) do
      :ok
    end
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name) when is_binary(issue_id) and is_binary(state_name) do
    tracker = Config.settings!().tracker

    with {:ok, repository} <- repository(tracker),
         {:ok, issue_ref} <- issue_reference(issue_id) do
      if terminal_state?(state_name, tracker.terminal_states) do
        close_issue(repository, issue_ref, state_name)
      else
        update_issue_status_label(tracker, repository, issue_ref, state_name)
      end
    end
  end

  @doc false
  @spec normalize_issue_for_test(map(), map(), String.t()) :: Issue.t() | nil
  def normalize_issue_for_test(issue, tracker, repository)
      when is_map(issue) and is_map(tracker) and is_binary(repository) do
    normalize_issue(issue, tracker, repository)
  end

  @doc false
  @spec issue_reference_for_test(String.t()) :: {:ok, String.t()} | {:error, term()}
  def issue_reference_for_test(issue_id), do: issue_reference(issue_id)

  defp fetch_closed_issues([]), do: {:ok, []}

  defp fetch_closed_issues(state_names) do
    tracker = Config.settings!().tracker

    with {:ok, repository} <- repository(tracker),
         {:ok, issues} <-
           gh_json([
             "issue",
             "list",
             "--repo",
             repository,
             "--state",
             "closed",
             "--limit",
             Integer.to_string(@issue_limit),
             "--json",
             @issue_fields
           ]) do
      requested_states = MapSet.new(state_names)

      normalized =
        issues
        |> Enum.map(&normalize_issue(&1, tracker, repository))
        |> Enum.filter(&match?(%Issue{}, &1))
        |> Enum.filter(&MapSet.member?(requested_states, &1.state))

      {:ok, normalized}
    end
  end

  defp fetch_open_issues_by_states([]), do: {:ok, []}

  defp fetch_open_issues_by_states(state_names) do
    tracker = Config.settings!().tracker

    with {:ok, repository} <- repository(tracker),
         {:ok, issues} <-
           gh_json([
             "issue",
             "list",
             "--repo",
             repository,
             "--state",
             "open",
             "--label",
             tracker.dispatch_label,
             "--limit",
             Integer.to_string(@issue_limit),
             "--json",
             @issue_fields
           ]) do
      requested_states = MapSet.new(state_names)

      normalized =
        issues
        |> Enum.map(&normalize_issue(&1, tracker, repository))
        |> Enum.filter(&match?(%Issue{}, &1))
        |> Enum.filter(&MapSet.member?(requested_states, &1.state))

      {:ok, normalized}
    end
  end

  defp fetch_issue_by_id(issue_id, tracker, repository) do
    with {:ok, issue_ref} <- issue_reference(issue_id),
         {:ok, issue} <- gh_json(["issue", "view", issue_ref, "--repo", repository, "--json", @issue_fields]) do
      {:ok, normalize_issue(issue, tracker, repository)}
    end
  end

  defp update_issue_status_label(tracker, repository, issue_ref, state_name) do
    with {:ok, desired_label} <- status_label_for_state(tracker, state_name),
         {:ok, issue} <- gh_json(["issue", "view", issue_ref, "--repo", repository, "--json", @issue_fields]) do
      existing_status_labels =
        issue
        |> raw_label_names()
        |> Enum.filter(&status_label_to_remove?(&1, tracker, desired_label))

      args =
        ["issue", "edit", issue_ref, "--repo", repository, "--add-label", desired_label] ++
          Enum.flat_map(existing_status_labels, &["--remove-label", &1])

      case gh(args) do
        {:ok, _output} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp close_issue(repository, issue_ref, state_name) do
    reason =
      case normalize_state_name(state_name) do
        "closed" -> "not planned"
        "cancelled" -> "not planned"
        "canceled" -> "not planned"
        "duplicate" -> "not planned"
        _ -> "completed"
      end

    case gh(["issue", "close", issue_ref, "--repo", repository, "--reason", reason]) do
      {:ok, _output} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp terminal_state?(state_name, terminal_states) do
    normalized_state = normalize_state_name(state_name)

    Enum.any?(terminal_states, fn terminal_state ->
      normalize_state_name(terminal_state) == normalized_state
    end)
  end

  defp normalize_issue(issue, tracker, repository) when is_map(issue) do
    number = issue["number"]

    %Issue{
      id: "github:#{repository}##{number}",
      identifier: "GH-#{number}",
      title: issue["title"],
      description: issue["body"],
      priority: nil,
      state: issue_state(issue, tracker),
      branch_name: nil,
      url: issue["url"],
      assignee_id: nil,
      blocked_by: [],
      labels: label_names(issue),
      assigned_to_worker: true,
      created_at: parse_datetime(issue["createdAt"]),
      updated_at: parse_datetime(issue["updatedAt"])
    }
  end

  defp normalize_issue(_issue, _tracker, _repository), do: nil

  defp issue_state(%{"state" => "CLOSED"} = issue, _tracker) do
    case issue["stateReason"] do
      "NOT_PLANNED" -> "Closed"
      _ -> "Done"
    end
  end

  defp issue_state(issue, tracker) do
    labels = issue |> label_names() |> MapSet.new()

    cond do
      status_label_present?(labels, tracker.status_labels["blocked"]) -> "Blocked"
      status_label_present?(labels, tracker.status_labels["human_review"]) -> "Human Review"
      status_label_present?(labels, tracker.status_labels["rework"]) -> "Rework"
      status_label_present?(labels, tracker.status_labels["in_progress"]) -> "In Progress"
      true -> "Todo"
    end
  end

  defp label_names(issue) do
    issue
    |> raw_label_names()
    |> Enum.map(&normalize_label/1)
  end

  defp raw_label_names(%{"labels" => labels}) when is_list(labels) do
    labels
    |> Enum.map(&label_name/1)
    |> Enum.reject(&is_nil/1)
  end

  defp raw_label_names(_issue), do: []

  defp label_name(%{"name" => name}) when is_binary(name), do: name
  defp label_name(_label), do: nil

  defp status_label_present?(labels, status_label) do
    MapSet.member?(labels, normalize_label(status_label))
  end

  defp status_label_to_remove?(label, tracker, desired_label) do
    normalized_label = normalize_label(label)
    desired_label = normalize_label(desired_label)

    status_label? =
      tracker.status_labels
      |> Map.values()
      |> Enum.map(&normalize_label/1)
      |> MapSet.new()
      |> MapSet.member?(normalized_label)

    status_label? and normalized_label != desired_label
  end

  defp status_label_for_state(tracker, state_name) do
    case normalize_state_name(state_name) do
      "todo" -> {:ok, tracker.status_labels["todo"]}
      "in progress" -> {:ok, tracker.status_labels["in_progress"]}
      "rework" -> {:ok, tracker.status_labels["rework"]}
      "human review" -> {:ok, tracker.status_labels["human_review"]}
      "blocked" -> {:ok, tracker.status_labels["blocked"]}
      other -> {:error, {:unsupported_github_status_state, other}}
    end
  end

  defp normalize_state_name(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
    |> String.replace("_", " ")
  end

  defp normalize_state_name(state_name), do: state_name |> to_string() |> normalize_state_name()

  defp normalize_label(label) when is_binary(label) do
    label
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_label(label), do: label |> to_string() |> normalize_label()

  defp parse_datetime(nil), do: nil

  defp parse_datetime(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp issue_reference("github:" <> rest) do
    case String.split(rest, "#", parts: 2) do
      [_repository, number] when number != "" -> {:ok, number}
      _ -> {:error, {:invalid_github_issue_id, "github:" <> rest}}
    end
  end

  defp issue_reference("GH-" <> number) when number != "", do: {:ok, number}
  defp issue_reference("#" <> number) when number != "", do: {:ok, number}

  defp issue_reference(issue_id) when is_binary(issue_id) do
    if String.match?(issue_id, ~r/^\d+$/) do
      {:ok, issue_id}
    else
      {:error, {:unsupported_github_issue_id, issue_id}}
    end
  end

  defp repository(tracker) do
    case tracker.repository do
      repository when is_binary(repository) and repository != "" -> {:ok, repository}
      _ -> {:error, :missing_github_repository}
    end
  end

  defp gh_json(args) do
    with {:ok, output} <- gh(args),
         {:ok, decoded} <- Jason.decode(output) do
      {:ok, decoded}
    else
      {:error, %Jason.DecodeError{} = error} -> {:error, {:github_gh_json_decode, Exception.message(error)}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp gh(args) when is_list(args) do
    runner = Application.get_env(:symphony_elixir, :github_gh_runner, &run_gh/1)
    runner.(args)
  end

  defp run_gh(args) do
    {output, status} = System.cmd("gh", args, stderr_to_stdout: true, env: gh_env())

    if status == 0 do
      {:ok, output}
    else
      Logger.error("GitHub gh command failed status=#{status} args=#{inspect(args)} output=#{inspect(output)}")
      {:error, {:github_gh_exit, status, output}}
    end
  rescue
    error in ErlangError ->
      {:error, {:github_gh_error, error.original}}
  end

  defp gh_env do
    case Config.settings!().tracker.api_key do
      token when is_binary(token) and token != "" -> [{"GH_TOKEN", token}]
      _ -> []
    end
  end
end
