import { act, fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { ApiError } from "../../api/client";
import { baseBackupsApi } from "../../api/baseBackups";
import { playersApi } from "../../api/players";
import { BaseBackupsView } from "./BaseBackupsView";

vi.mock("../../api/baseBackups", () => ({
  baseBackupsApi: { list: vi.fn(), download: vi.fn(), importFile: vi.fn(), update: vi.fn(), remove: vi.fn() }
}));
vi.mock("../../api/players", () => ({ playersApi: { list: vi.fn() } }));

const backup = {
  id: 3,
  ownerControllerId: 4,
  ownerPawnId: 6,
  ownerName: "Owner One",
  name: "Test Base",
  rawName: "Test Base",
  map: "DeepDesert",
  totemType: "Totem_Small_Placeable",
  pieces: 24,
  placeables: 8,
  items: 13
};

const importResult = {
  ok: true as const,
  backupId: 9,
  name: "Test Base",
  playerPawnId: 38,
  playerControllerId: 36,
  online: false,
  counts: { actors: 9, pieces: 24, placeables: 8, items: 13 },
  version: { mismatch: false, file: { build: "1", patchesChecksum: "a", appliedPatchesCount: 1 }, server: { build: "1", patchesChecksum: "a", appliedPatchesCount: 1 } },
  warnings: []
};

const timeoutBody = (operation: "import" | "export") => ({
  ok: false,
  code: "timeout",
  operation,
  step: operation === "import" ? "inserting building pieces" : "exporting stored items",
  timeoutKind: "server_timeout",
  elapsedMs: 120400,
  limitMs: 120000,
  error: operation === "import"
    ? "Base backup import timed out after 120.4s while inserting building pieces (limit 120s). Nothing was changed: the import was rolled back."
    : "Base backup export timed out after 120.4s while exporting stored items (limit 120s). No file was produced."
});

function chooseFile() {
  const input = screen.getByLabelText("Base backup file") as HTMLInputElement;
  const file = new File(['{"format":"dune-base-backup"}'], "test-base.json", { type: "application/json" });
  fireEvent.change(input, { target: { files: [file] } });
  return file;
}

async function pickReceiver() {
  fireEvent.change(screen.getByLabelText("Search for the receiving player"), { target: { value: "Rec" } });
  fireEvent.click(screen.getByRole("button", { name: "Search" }));
  fireEvent.click(await screen.findByRole("button", { name: "Import to Receiver Two" }));
}

beforeEach(() => {
  vi.clearAllMocks();
  vi.mocked(baseBackupsApi.list).mockResolvedValue({ supported: true, rows: [backup], maps: ["DeepDesert", "HaggaBasin"] });
  vi.mocked(playersApi.list).mockResolvedValue({
    rows: [{ actor_id: 38, character_name: "Receiver Two", online_status: "Offline" }],
    totalCount: 1, totalPlayers: 1, capabilities: {}
  });
  URL.createObjectURL = vi.fn(() => "blob:backup");
  URL.revokeObjectURL = vi.fn();
});

afterEach(() => {
  vi.useRealTimers();
});

describe("BaseBackupsView", () => {
  it("lists every backup with its owner, map and contents", async () => {
    render(<BaseBackupsView onError={vi.fn()} confirmAction={vi.fn()} />);
    expect(await screen.findByText("Test Base")).toBeInTheDocument();
    expect(screen.getByRole("heading", { name: "Base Backups" })).toBeInTheDocument();
    expect(screen.getByText("Owner One")).toBeInTheDocument();
    expect(screen.getByText("Deep Desert")).toBeInTheDocument();
    expect(screen.getByText("24")).toBeInTheDocument();
    expect(baseBackupsApi.list).toHaveBeenCalledWith("");
  });

  it("downloads an export using the server's file name", async () => {
    vi.mocked(baseBackupsApi.download).mockResolvedValue(new Response("{}", {
      headers: { "content-disposition": 'attachment; filename="Owner_One_Test_Base_base-backup_3.json"' }
    }));
    const click = vi.spyOn(HTMLAnchorElement.prototype, "click").mockImplementation(() => {});
    render(<BaseBackupsView onError={vi.fn()} confirmAction={vi.fn()} />);
    fireEvent.click(await screen.findByRole("button", { name: "Export Test Base" }));
    expect(await screen.findByText("Base Backup Exported")).toBeInTheDocument();
    expect(baseBackupsApi.download).toHaveBeenCalledWith(3);
    const anchor = click.mock.instances[0] as unknown as HTMLAnchorElement;
    expect(anchor.download).toBe("Owner_One_Test_Base_base-backup_3.json");
    click.mockRestore();
  });

  it("imports a file for the player chosen by search, after confirmation", async () => {
    vi.mocked(baseBackupsApi.importFile).mockResolvedValue({ ...importResult, warnings: ["The receiving player is online."] });
    const confirmAction = vi.fn().mockResolvedValue(true);
    render(<BaseBackupsView onError={vi.fn()} confirmAction={confirmAction} />);
    await screen.findByText("Test Base");
    const file = chooseFile();
    expect(screen.getByRole("button", { name: /Import$/ })).toBeDisabled();
    await pickReceiver();
    expect(playersApi.list).toHaveBeenCalledWith({ q: "Rec", pageSize: 25 });
    expect(screen.getByText("Receiver Two")).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: /Import$/ }));
    await waitFor(() => expect(baseBackupsApi.importFile).toHaveBeenCalledWith(file, "38", false));
    expect(confirmAction).toHaveBeenCalledWith(expect.stringContaining("Receiver Two"), expect.objectContaining({ title: "Import Base Backup", confirmLabel: "Import" }));
    expect(await screen.findByText("Base Backup Imported")).toBeInTheDocument();
    expect(screen.getByText(/24 pieces, 8 placeables and 13 stored items/)).toBeInTheDocument();
    // Warnings are visible text, and a result carrying one does not fade away.
    const warning = screen.getByText(/The receiving player is online/);
    expect(warning.closest(".home-task-result-warnings")).not.toBeNull();
    expect(warning.closest(".result-panel")).toHaveClass("result-persistent");
  });

  it("offers Import Anyway on a game version mismatch and resends with the override", async () => {
    vi.mocked(baseBackupsApi.importFile)
      .mockRejectedValueOnce(new ApiError("This base backup was exported from a different game version.", 409, {
        code: "version_mismatch",
        file: { build: "1999999", patchesChecksum: "0000", appliedPatchesCount: 900 },
        server: { build: "2036754", patchesChecksum: "d9dd", appliedPatchesCount: 921 }
      }))
      .mockResolvedValueOnce({ ...importResult, warnings: ["Imported despite a game version mismatch between the file and this server."] });
    const confirmAction = vi.fn().mockResolvedValue(true);
    render(<BaseBackupsView onError={vi.fn()} confirmAction={confirmAction} />);
    await screen.findByText("Test Base");
    const file = chooseFile();
    await pickReceiver();
    fireEvent.click(screen.getByRole("button", { name: /Import$/ }));
    expect(await screen.findByText("Base Backup Imported")).toBeInTheDocument();
    expect(baseBackupsApi.importFile).toHaveBeenNthCalledWith(1, file, "38", false);
    expect(baseBackupsApi.importFile).toHaveBeenNthCalledWith(2, file, "38", true);
    const mismatchPrompt = confirmAction.mock.calls[1][1];
    expect(mismatchPrompt).toMatchObject({ title: "Game Version Mismatch", confirmLabel: "Import Anyway", danger: true });
    expect(mismatchPrompt.details).toEqual(expect.arrayContaining([
      expect.objectContaining({ label: "File game build", value: "1999999" }),
      expect.objectContaining({ label: "This server's build", value: "2036754" })
    ]));
  });

  it("does not resend when Import Anyway is declined", async () => {
    vi.mocked(baseBackupsApi.importFile).mockRejectedValueOnce(new ApiError("different version", 409, { code: "version_mismatch" }));
    const confirmAction = vi.fn().mockResolvedValueOnce(true).mockResolvedValueOnce(false);
    render(<BaseBackupsView onError={vi.fn()} confirmAction={confirmAction} />);
    await screen.findByText("Test Base");
    chooseFile();
    await pickReceiver();
    fireEvent.click(screen.getByRole("button", { name: /Import$/ }));
    await waitFor(() => expect(confirmAction).toHaveBeenCalledTimes(2));
    expect(baseBackupsApi.importFile).toHaveBeenCalledTimes(1);
    expect(screen.queryByText("Base Backup Imported")).not.toBeInTheDocument();
  });

  it("shows an import timeout with its step and keeps it on screen", async () => {
    vi.useFakeTimers({ shouldAdvanceTime: true });
    vi.mocked(baseBackupsApi.importFile).mockRejectedValue(new ApiError(timeoutBody("import").error, 504, timeoutBody("import")));
    render(<BaseBackupsView onError={vi.fn()} confirmAction={vi.fn().mockResolvedValue(true)} />);
    await screen.findByText("Test Base");
    chooseFile();
    await pickReceiver();
    fireEvent.click(screen.getByRole("button", { name: /Import$/ }));
    expect(await screen.findByText("Import Timed Out")).toBeInTheDocument();
    expect(screen.getByText(/while inserting building pieces \(limit 120s\)\. Nothing was changed/)).toBeInTheDocument();
    fireEvent.click(screen.getByText(/Technical details|Details/i));
    expect(screen.getByText(/Step: inserting building pieces/)).toBeInTheDocument();
    // Success results clear after ~10 s; a timeout must not -- neither from
    // the DOM nor visually (result-persistent cancels the CSS fade-out).
    await act(async () => { vi.advanceTimersByTime(15000); });
    expect(screen.getByText("Import Timed Out")).toBeInTheDocument();
    expect(screen.getByText("Import Timed Out").closest(".result-panel")).toHaveClass("result-persistent");
    fireEvent.click(screen.getByRole("button", { name: "Dismiss" }));
    expect(screen.queryByText("Import Timed Out")).not.toBeInTheDocument();
  });

  it("shows an export timeout instead of a generic download failure", async () => {
    vi.mocked(baseBackupsApi.download).mockRejectedValue(new ApiError(timeoutBody("export").error, 504, timeoutBody("export")));
    render(<BaseBackupsView onError={vi.fn()} confirmAction={vi.fn()} />);
    fireEvent.click(await screen.findByRole("button", { name: "Export Test Base" }));
    expect(await screen.findByText("Export Timed Out")).toBeInTheDocument();
    expect(screen.getByText(/No file was produced/)).toBeInTheDocument();
    expect(screen.queryByText("Base Backup Export Failed")).not.toBeInTheDocument();
  });

  it("embedded in a player's view, lists their backups and imports to them without a search", async () => {
    vi.mocked(baseBackupsApi.importFile).mockResolvedValue(importResult);
    const confirmAction = vi.fn().mockResolvedValue(true);
    render(<BaseBackupsView embedded playerId="6" playerName="Owner One" playerOnline onError={vi.fn()} confirmAction={confirmAction} />);
    await screen.findByText("Test Base");
    expect(baseBackupsApi.list).toHaveBeenCalledWith("6");
    expect(screen.queryByLabelText("Search for the receiving player")).not.toBeInTheDocument();
    const file = chooseFile();
    fireEvent.click(screen.getByRole("button", { name: /Import$/ }));
    await waitFor(() => expect(baseBackupsApi.importFile).toHaveBeenCalledWith(file, "6", false));
    // The open player's online status reaches the confirmation.
    expect(confirmAction.mock.calls[0][1]).toMatchObject({ warning: expect.stringMatching(/Owner One is online/) });
  });

  it("explains when the game database cannot support backups", async () => {
    vi.mocked(baseBackupsApi.list).mockResolvedValue({ supported: false, rows: [], missing: ["dune._character_transfer_data_table_save()"] });
    render(<BaseBackupsView onError={vi.fn()} confirmAction={vi.fn()} />);
    expect(await screen.findByText("Base Backups Unavailable")).toBeInTheDocument();
    expect(screen.queryByLabelText("Base backup file")).not.toBeInTheDocument();
  });

  describe("editing owner and name", () => {
    async function openEditor() {
      render(<BaseBackupsView onError={vi.fn()} confirmAction={confirm} />);
      fireEvent.click(await screen.findByRole("button", { name: "Edit Test Base" }));
      return screen.getByRole("group", { name: "Edit Test Base" });
    }
    let confirm = vi.fn();
    beforeEach(() => {
      confirm = vi.fn().mockResolvedValue(true);
    });

    it("opens in an expanded row directly under the backup being edited", async () => {
      vi.mocked(baseBackupsApi.list).mockResolvedValue({
        supported: true, maps: ["DeepDesert"],
        rows: [backup, { ...backup, id: 4, name: "Second Base", rawName: "Second Base" }]
      });
      const panel = await openEditor();
      const editedRow = screen.getByRole("button", { name: "Edit Test Base" }).closest("tr");
      const panelRow = panel.closest("tr");
      expect(panelRow).toHaveClass("expanded-row");
      expect(editedRow?.nextElementSibling).toBe(panelRow);
      fireEvent.click(within(panel).getByRole("button", { name: "Cancel" }));
      expect(screen.queryByRole("group", { name: "Edit Test Base" })).not.toBeInTheDocument();
    });

    it("renames a backup after confirmation, with Save gated on a real change", async () => {
      vi.mocked(baseBackupsApi.update).mockResolvedValue({ ok: true, backupId: 3, owner: null, name: { from: "Test Base", to: "North Wall" }, map: null, warnings: [] });
      const panel = await openEditor();
      const save = within(panel).getByRole("button", { name: "Save" });
      expect(save).toBeDisabled();
      const nameInput = within(panel).getByLabelText("Backup name");
      expect(nameInput).toHaveValue("Test Base");
      fireEvent.change(nameInput, { target: { value: "  North Wall " } });
      expect(save).toBeEnabled();
      fireEvent.click(save);
      await waitFor(() => expect(baseBackupsApi.update).toHaveBeenCalledWith(3, { name: "North Wall" }));
      expect(confirm).toHaveBeenCalledWith(expect.stringContaining('rename it to "North Wall"'), expect.objectContaining({ title: "Edit Base Backup" }));
      expect(await screen.findByText("Base Backup Updated")).toBeInTheDocument();
      expect(screen.getByText(/Renamed from "Test Base" to "North Wall"/)).toBeInTheDocument();
      expect(screen.queryByRole("group", { name: "Edit Test Base" })).not.toBeInTheDocument();
    });

    it("enforces the game-safe name rules before anything is sent", async () => {
      const panel = await openEditor();
      const nameInput = within(panel).getByLabelText("Backup name");
      const save = within(panel).getByRole("button", { name: "Save" });
      fireEvent.change(nameInput, { target: { value: "##Totem_Placeable" } });
      expect(within(panel).getByText("Backup name cannot start with ##.")).toBeInTheDocument();
      expect(save).toBeDisabled();
      fireEvent.change(nameInput, { target: { value: "   " } });
      expect(within(panel).getByText("Backup name cannot be empty.")).toBeInTheDocument();
      expect(save).toBeDisabled();
      expect(baseBackupsApi.update).not.toHaveBeenCalled();
    });

    it("reassigns through its own player search and warns when the new owner is online", async () => {
      vi.mocked(playersApi.list).mockResolvedValue({
        rows: [{ actor_id: 38, character_name: "Receiver Two", online_status: "Online" }],
        totalCount: 1, totalPlayers: 1, capabilities: {}
      });
      vi.mocked(baseBackupsApi.update).mockResolvedValue({
        ok: true, backupId: 3, owner: { from: 4, fromName: "Owner One", to: 36 }, name: null, map: null,
        warnings: ["The new owner is online. They must log out and back in before the backup appears in their base backup tool."]
      });
      const panel = await openEditor();
      fireEvent.change(within(panel).getByLabelText("Search for the new owner"), { target: { value: "Rec" } });
      fireEvent.click(within(panel).getByRole("button", { name: "Search" }));
      fireEvent.click(await within(panel).findByRole("button", { name: "Make Receiver Two the owner" }));
      expect(within(panel).getByText(/was Owner One/)).toBeInTheDocument();
      fireEvent.click(within(panel).getByRole("button", { name: "Save" }));
      await waitFor(() => expect(baseBackupsApi.update).toHaveBeenCalledWith(3, { ownerPlayerId: "38" }));
      expect(confirm.mock.calls[0][1]).toMatchObject({ warning: expect.stringMatching(/Receiver Two is online and must log out and back in/) });
      expect(await screen.findByText(/Owner changed from Owner One to Receiver Two/)).toBeInTheDocument();
      const warning = screen.getByText(/new owner is online/);
      expect(warning.closest(".result-panel")).toHaveClass("result-persistent");
    });

    it("moves a backup to another map, warning where it can then be placed", async () => {
      vi.mocked(baseBackupsApi.update).mockResolvedValue({
        ok: true, backupId: 3, owner: null, name: null, map: { from: "DeepDesert", to: "HaggaBasin", actors: 9 }, warnings: []
      });
      const panel = await openEditor();
      expect(within(panel).getByRole("radio", { name: "Deep Desert" })).toBeChecked();
      fireEvent.click(within(panel).getByRole("radio", { name: "Hagga Basin" }));
      fireEvent.click(within(panel).getByRole("button", { name: "Save" }));
      await waitFor(() => expect(baseBackupsApi.update).toHaveBeenCalledWith(3, { map: "HaggaBasin" }));
      expect(confirm).toHaveBeenCalledWith(expect.stringContaining("move it to Hagga Basin"),
        expect.objectContaining({ warning: expect.stringMatching(/only be redeployed on Hagga Basin, not on Deep Desert/) }));
      expect(await screen.findByText(/Moved from Deep Desert to Hagga Basin/)).toBeInTheDocument();
    });

    it("explains that the current owner has to log out", async () => {
      vi.mocked(baseBackupsApi.update).mockRejectedValue(new ApiError("Owner One is online. They must log out before this backup can be changed.", 409, { code: "owner_online" }));
      const panel = await openEditor();
      fireEvent.change(within(panel).getByLabelText("Backup name"), { target: { value: "North Wall" } });
      fireEvent.click(within(panel).getByRole("button", { name: "Save" }));
      expect(await screen.findByText("Owner Is Online")).toBeInTheDocument();
      expect(screen.getByText(/must log out before this backup can be changed/)).toBeInTheDocument();
      // The form stays open so the change can be retried once they log out.
      expect(screen.getByRole("group", { name: "Edit Test Base" })).toBeInTheDocument();
    });

    it("reloads the list when the backup was redeployed meanwhile", async () => {
      vi.mocked(baseBackupsApi.update).mockRejectedValue(new ApiError("Base backup 3 no longer exists.", 404, { code: "not_found" }));
      const panel = await openEditor();
      fireEvent.change(within(panel).getByLabelText("Backup name"), { target: { value: "North Wall" } });
      fireEvent.click(within(panel).getByRole("button", { name: "Save" }));
      expect(await screen.findByText("Backup No Longer Exists")).toBeInTheDocument();
      await waitFor(() => expect(baseBackupsApi.list).toHaveBeenCalledTimes(2));
    });
  });

  describe("deleting", () => {
    it("deletes after a danger confirmation that lists what will be destroyed", async () => {
      vi.mocked(baseBackupsApi.remove).mockResolvedValue({
        ok: true, backupId: 3, name: "Test Base", ownerName: "Owner One", map: "DeepDesert",
        counts: { pieces: 24, placeables: 8, items: 13 }, backupCreated: true
      });
      const confirmAction = vi.fn().mockResolvedValue(true);
      render(<BaseBackupsView onError={vi.fn()} confirmAction={confirmAction} />);
      fireEvent.click(await screen.findByRole("button", { name: "Delete Test Base" }));
      await waitFor(() => expect(baseBackupsApi.remove).toHaveBeenCalledWith(3));
      const [message, options] = confirmAction.mock.calls[0];
      expect(message).toMatch(/permanently deletes the base and everything stored in it/);
      expect(options).toMatchObject({ title: "Delete Base Backup", confirmLabel: "Delete", danger: true });
      expect(options.warning).toMatch(/full database backup is taken automatically/);
      expect(options.details).toEqual(expect.arrayContaining([
        expect.objectContaining({ label: "Stored Items", value: "13" }),
        expect.objectContaining({ label: "Map", value: "Deep Desert" })
      ]));
      expect(await screen.findByText("Base Backup Deleted")).toBeInTheDocument();
      expect(screen.getByText(/A full database backup was taken first/)).toBeInTheDocument();
      expect(baseBackupsApi.list).toHaveBeenCalledTimes(2);
    });

    it("does nothing when the confirmation is declined", async () => {
      render(<BaseBackupsView onError={vi.fn()} confirmAction={vi.fn().mockResolvedValue(false)} />);
      fireEvent.click(await screen.findByRole("button", { name: "Delete Test Base" }));
      await waitFor(() => expect(baseBackupsApi.list).toHaveBeenCalledTimes(1));
      expect(baseBackupsApi.remove).not.toHaveBeenCalled();
    });

    it("says the owner must log out when they are online", async () => {
      vi.mocked(baseBackupsApi.remove).mockRejectedValue(new ApiError("Owner One is online. They must log out before this backup can be deleted.", 409, { code: "owner_online" }));
      render(<BaseBackupsView onError={vi.fn()} confirmAction={vi.fn().mockResolvedValue(true)} />);
      fireEvent.click(await screen.findByRole("button", { name: "Delete Test Base" }));
      expect(await screen.findByText("Owner Is Online")).toBeInTheDocument();
      expect(screen.getByText(/must log out before this backup can be deleted/)).toBeInTheDocument();
    });
  });
});
