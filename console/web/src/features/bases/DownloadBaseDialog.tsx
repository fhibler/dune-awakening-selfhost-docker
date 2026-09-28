import { useEffect, useRef, useState } from "react";
import { Download, X } from "lucide-react";
import { apiDownload } from "../../api/client";
import { baseBackupsApi } from "../../api/baseBackups";
import { saveDownload } from "./saveDownload";

export type DownloadBaseTarget = { id: string; name: string; ownerName: string };

type Format = "blueprint" | "backup";

function errorText(error: unknown) {
  return error instanceof Error ? error.message : String(error);
}

function fileStem(value: string) {
  return value.replace(/[^a-zA-Z0-9_-]/g, "_");
}

// "Download Base": the base as a blueprint (its layout) or as a base backup
// (the whole base, importable in Base Backups). Errors are shown here, not
// through the panel's banner, which sits behind this dialog's scrim.
export function DownloadBaseDialog({ base, onClose }: { base: DownloadBaseTarget; onClose: () => void }) {
  const [busy, setBusy] = useState<Format | null>(null);
  const [error, setError] = useState("");
  const closeButtonRef = useRef<HTMLButtonElement>(null);
  const dialogRef = useRef<HTMLElement>(null);
  const busyRef = useRef(busy);
  busyRef.current = busy;

  // Focus moves into the dialog, stays there (Tab wraps), and goes back to
  // whatever opened it when it closes.
  useEffect(() => {
    const opener = document.activeElement instanceof HTMLElement ? document.activeElement : null;
    closeButtonRef.current?.focus();
    return () => opener?.focus();
  }, []);

  useEffect(() => {
    function onKeyDown(event: KeyboardEvent) {
      if (event.key === "Escape" && !busyRef.current) onClose();
      if (event.key !== "Tab" || !dialogRef.current) return;
      const focusable = [...dialogRef.current.querySelectorAll<HTMLElement>("button:not([disabled])")];
      if (!focusable.length) {
        event.preventDefault();
        return;
      }
      const first = focusable[0];
      const last = focusable[focusable.length - 1];
      const inside = dialogRef.current.contains(document.activeElement);
      if (event.shiftKey && (document.activeElement === first || !inside)) {
        event.preventDefault();
        last.focus();
      } else if (!event.shiftKey && (document.activeElement === last || !inside)) {
        event.preventDefault();
        first.focus();
      }
    }
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, [onClose]);

  async function download(format: Format) {
    setBusy(format);
    setError("");
    try {
      const id = encodeURIComponent(base.id);
      if (format === "blueprint") {
        await saveDownload(await apiDownload(`/api/bases/${id}/export`), `${fileStem(base.ownerName || "unknown_player")}_base_${base.id}.json`);
      } else {
        await saveDownload(await baseBackupsApi.downloadLiveBase(base.id), `base-backup_live_${base.id}.json`);
      }
      onClose();
    } catch (failure) {
      setError(errorText(failure));
      setBusy(null);
    }
  }

  const label = base.name || `base ${base.id}`;
  return <div className="modal-overlay" role="presentation" onMouseDown={() => { if (!busy) onClose(); }}>
    <section ref={dialogRef} className="confirm-modal confirm-modal-wide download-base-modal" role="dialog" aria-modal="true" aria-labelledby="download-base-title" onMouseDown={(event) => event.stopPropagation()}>
      <div className="confirm-modal-title">
        <h3 id="download-base-title">Download Base</h3>
        <button ref={closeButtonRef} className="icon-action" aria-label="Close dialog" disabled={busy !== null} onClick={onClose}><X size={18} /></button>
      </div>
      <p>Choose how to download <strong>{label}</strong>{base.ownerName ? ` (${base.ownerName})` : ""}.</p>
      <div className="download-base-options">
        <div className="download-base-option">
          <div>
            <strong>Blueprint</strong>
            <p>Layout only: building pieces and placeables. Placed in-game as a blueprint and built with materials. Storage contents are not included.</p>
          </div>
          <button className="success" disabled={busy !== null} onClick={() => void download("blueprint")}>
            <Download size={16} /> {busy === "blueprint" ? "Downloading..." : "Download Blueprint"}
          </button>
        </div>
        <div className="download-base-option">
          <div>
            <strong>Base Backup</strong>
            <p>The whole base, including everything stored in it. Import it in Base Backups for any player, who redeploys it with the in-game base backup tool.</p>
          </div>
          <button className="success" disabled={busy !== null} onClick={() => void download("backup")}>
            <Download size={16} /> {busy === "backup" ? "Downloading..." : "Download Base Backup"}
          </button>
        </div>
      </div>
      <p className="action-help-note">A base backup reflects the base as of the map server's last save. The base itself is not changed.</p>
      {error && <div className="confirm-modal-warning" role="alert">{error}</div>}
      <div className="confirm-modal-actions">
        <button disabled={busy !== null} onClick={onClose}>Cancel</button>
      </div>
    </section>
  </div>;
}
