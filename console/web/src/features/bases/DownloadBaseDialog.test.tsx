import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { ApiError, apiDownload } from "../../api/client";
import { baseBackupsApi } from "../../api/baseBackups";
import { DownloadBaseDialog } from "./DownloadBaseDialog";
import { saveDownload } from "./saveDownload";

vi.mock("../../api/client", async (importOriginal) => ({
  ...await importOriginal<typeof import("../../api/client")>(),
  apiDownload: vi.fn()
}));
vi.mock("../../api/baseBackups", () => ({ baseBackupsApi: { downloadLiveBase: vi.fn() } }));
vi.mock("./saveDownload", () => ({ saveDownload: vi.fn() }));

const base = { id: "176", name: "Owned Home", ownerName: "Chani Kynes" };
const response = new Response("{}");

beforeEach(() => {
  vi.clearAllMocks();
  vi.mocked(apiDownload).mockResolvedValue(response);
  vi.mocked(baseBackupsApi.downloadLiveBase).mockResolvedValue(response);
  vi.mocked(saveDownload).mockResolvedValue();
});

describe("DownloadBaseDialog", () => {
  it("downloads the base as a blueprint and closes", async () => {
    const onClose = vi.fn();
    render(<DownloadBaseDialog base={base} onClose={onClose} />);
    expect(screen.getByRole("dialog", { name: "Download Base" })).toHaveTextContent("Owned Home (Chani Kynes)");
    fireEvent.click(screen.getByRole("button", { name: /Download Blueprint/ }));
    await waitFor(() => expect(onClose).toHaveBeenCalled());
    expect(apiDownload).toHaveBeenCalledWith("/api/bases/176/export");
    expect(saveDownload).toHaveBeenCalledWith(response, "Chani_Kynes_base_176.json");
    expect(baseBackupsApi.downloadLiveBase).not.toHaveBeenCalled();
  });

  it("downloads the base as a base backup and closes", async () => {
    const onClose = vi.fn();
    render(<DownloadBaseDialog base={base} onClose={onClose} />);
    fireEvent.click(screen.getByRole("button", { name: /Download Base Backup/ }));
    await waitFor(() => expect(onClose).toHaveBeenCalled());
    expect(baseBackupsApi.downloadLiveBase).toHaveBeenCalledWith("176");
    expect(saveDownload).toHaveBeenCalledWith(response, "base-backup_live_176.json");
    expect(apiDownload).not.toHaveBeenCalled();
  });

  it("locks both choices while a download runs", async () => {
    let finish: (value: Response) => void = () => {};
    vi.mocked(baseBackupsApi.downloadLiveBase).mockReturnValue(new Promise((resolve) => { finish = resolve; }));
    const onClose = vi.fn();
    render(<DownloadBaseDialog base={base} onClose={onClose} />);
    fireEvent.click(screen.getByRole("button", { name: /Download Base Backup/ }));
    expect(await screen.findByRole("button", { name: /Downloading/ })).toBeDisabled();
    expect(screen.getByRole("button", { name: /Download Blueprint/ })).toBeDisabled();
    expect(screen.getByRole("button", { name: "Cancel" })).toBeDisabled();
    fireEvent.keyDown(window, { key: "Escape" });
    expect(onClose).not.toHaveBeenCalled();
    finish(response);
    await waitFor(() => expect(onClose).toHaveBeenCalled());
  });

  it("shows a refusal in the dialog and stays open", async () => {
    vi.mocked(baseBackupsApi.downloadLiveBase).mockRejectedValue(new ApiError(
      "This base has no owner, so it cannot be saved as a base backup. Download it as a blueprint instead.", 409, { code: "no_owner" }));
    const onClose = vi.fn();
    render(<DownloadBaseDialog base={base} onClose={onClose} />);
    fireEvent.click(screen.getByRole("button", { name: /Download Base Backup/ }));
    expect(await screen.findByRole("alert")).toHaveTextContent("Download it as a blueprint instead.");
    expect(onClose).not.toHaveBeenCalled();
    expect(screen.getByRole("button", { name: /Download Blueprint/ })).toBeEnabled();
  });

  it("keeps Tab inside the dialog and returns focus to the opener when it closes", () => {
    const opener = document.createElement("button");
    opener.textContent = "Download Base";
    document.body.appendChild(opener);
    opener.focus();
    const { unmount } = render(<DownloadBaseDialog base={base} onClose={vi.fn()} />);
    const close = screen.getByRole("button", { name: "Close dialog" });
    const cancel = screen.getByRole("button", { name: "Cancel" });
    expect(close).toHaveFocus();
    // Shift+Tab from the first control wraps to the last, Tab from the last to the first.
    fireEvent.keyDown(window, { key: "Tab", shiftKey: true });
    expect(cancel).toHaveFocus();
    fireEvent.keyDown(window, { key: "Tab" });
    expect(close).toHaveFocus();
    unmount();
    expect(opener).toHaveFocus();
    opener.remove();
  });

  it("closes on Cancel and on Escape", () => {
    const onClose = vi.fn();
    render(<DownloadBaseDialog base={base} onClose={onClose} />);
    fireEvent.click(screen.getByRole("button", { name: "Cancel" }));
    fireEvent.keyDown(window, { key: "Escape" });
    expect(onClose).toHaveBeenCalledTimes(2);
  });
});
