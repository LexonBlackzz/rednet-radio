#!/usr/bin/env python3
import json
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path
import tkinter as tk
from tkinter import filedialog, messagebox, scrolledtext, ttk
from urllib.error import HTTPError, URLError
from urllib.parse import quote, unquote, urlparse
from urllib.request import Request, urlopen

DEFAULT_PUBLIC_BASE = "https://raw.githubusercontent.com/LexonBlackzz/rednet-radio/main"
DEFAULT_SAMPLE_RATE = 48000
DEFAULT_LOWPASS_HZ = 12000
DEFAULT_LIMIT = 0.90
STUDIO_CONFIG_NAME = "radio_studio.local.json"
DEFAULT_STUDIO_CONFIG = {
    "filegarden_user_id": "",
    "filegarden_auth_cookie": "",
    "filegarden_base_url": "",
    "catbox_userhash": "",
    "local_dfpwm_folder": "",
    "default_publish_target": "Local",
    "default_output_subfolder": "audio",
    "processing_normalize": False,
    "processing_tame_highs": False,
    "processing_lowpass_hz": DEFAULT_LOWPASS_HZ,
    "processing_dither_8bit": False,
    "processing_limiter": False,
    "processing_limit": DEFAULT_LIMIT,
}
CATBOX_API_URL = "https://catbox.moe/user/api.php"
FILE_GARDEN_UPLOAD_URL = "https://api.filegarden.com/users/{user_id}/pipe"
FILE_GARDEN_PUBLIC_URL = "https://file.garden/{user_id}/{path}"


def load_json(path: Path) -> dict:
    if not path.exists():
        return {}
    with path.open("r", encoding="utf-8-sig") as handle:
        return json.load(handle)


def save_json(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="\n") as handle:
        json.dump(data, handle, indent=2)
        handle.write("\n")


def normalize_github_url(url: str) -> str:
    if not url:
        return url
    parsed = urlparse(url)
    if parsed.netloc not in {"github.com", "www.github.com"}:
        return url
    parts = [part for part in parsed.path.split("/") if part]
    if len(parts) < 5 or parts[2] != "blob":
        return url
    owner, repo, _blob, branch = parts[:4]
    rest = "/".join(parts[4:])
    return f"https://raw.githubusercontent.com/{owner}/{repo}/{branch}/{rest}"


def bump_version(value) -> str:
    try:
        return str(int(str(value)) + 1)
    except (TypeError, ValueError):
        return datetime.now(timezone.utc).strftime("%Y%m%d%H%M%S")


def parse_duration(val: str) -> int:
    val = val.strip()
    if not val:
        raise ValueError("Empty duration")
    if ":" in val:
        parts = val.split(":")
        if len(parts) == 2:
            minutes, seconds = parts
            return int(minutes) * 60 + int(seconds)
        if len(parts) == 3:
            hours, minutes, seconds = parts
            return int(hours) * 3600 + int(minutes) * 60 + int(seconds)
        raise ValueError("Invalid time format")
    return int(val)


def format_duration(seconds: int) -> str:
    try:
        total_seconds = int(seconds)
        minutes = total_seconds // 60
        seconds_remainder = total_seconds % 60
        if minutes >= 60:
            hours = minutes // 60
            minutes = minutes % 60
            return f"{hours}:{minutes:02d}:{seconds_remainder:02d}"
        return f"{minutes}:{seconds_remainder:02d}"
    except (TypeError, ValueError):
        return str(seconds)


def encode_url_from_parts(base_url: str, relative_path: Path) -> str:
    encoded_parts = [quote(part) for part in relative_path.as_posix().split("/") if part]
    return base_url.rstrip("/") + "/" + "/".join(encoded_parts)


def load_studio_config(path: Path) -> dict:
    config = dict(DEFAULT_STUDIO_CONFIG)
    if path.exists():
        try:
            loaded = load_json(path)
            if isinstance(loaded, dict):
                config.update({k: loaded.get(k, v) for k, v in DEFAULT_STUDIO_CONFIG.items()})
        except (OSError, json.JSONDecodeError):
            pass
    return config


class RednetRadioStudio(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title("Rednet Radio Studio")
        self.geometry("1180x820")

        self.root_dir = Path.cwd()
        self.stations_file = None
        self.playlists_dir = None
        self.studio_config_path = None
        self.studio_config = dict(DEFAULT_STUDIO_CONFIG)
        self.editing_track_id = None
        self.ffmpeg_checked = False
        self.ffmpeg_available = False
        self.sub_tracks = []

        self.notebook = ttk.Notebook(self)
        self.notebook.pack(fill=tk.BOTH, expand=True, padx=10, pady=10)

        self.tab_stations = ttk.Frame(self.notebook)
        self.tab_playlist = ttk.Frame(self.notebook)
        self.tab_submit = ttk.Frame(self.notebook)

        self.notebook.add(self.tab_stations, text="1. Stations Manager")
        self.notebook.add(self.tab_playlist, text="2. Playlist Editor")
        self.notebook.add(self.tab_submit, text="3. Standalone Submissions")

        self.build_stations_tab()
        self.build_playlist_tab()
        self.build_submit_tab()

        self.notebook.bind("<<NotebookTabChanged>>", self.on_tab_change)
        self.load_workspace(self.root_dir)

    # --- UI BUILDING ---

    def build_stations_tab(self):
        top_frame = ttk.Frame(self.tab_stations)
        top_frame.pack(fill=tk.X, pady=5)
        ttk.Label(top_frame, text="Workspace:").pack(side=tk.LEFT)
        self.lbl_workspace = ttk.Label(top_frame, text="", font=("TkDefaultFont", 10, "bold"))
        self.lbl_workspace.pack(side=tk.LEFT, padx=10)
        ttk.Button(top_frame, text="Change Directory", command=self.browse_workspace).pack(side=tk.RIGHT)

        content = ttk.PanedWindow(self.tab_stations, orient=tk.HORIZONTAL)
        content.pack(fill=tk.BOTH, expand=True)

        list_frame = ttk.LabelFrame(content, text="Existing Stations")
        content.add(list_frame, weight=1)
        self.station_tree = ttk.Treeview(list_frame, columns=("name",), show="headings")
        self.station_tree.heading("name", text="Station Name (ID)")
        self.station_tree.pack(fill=tk.BOTH, expand=True, padx=5, pady=5)

        form_frame = ttk.LabelFrame(content, text="Create New Station")
        content.add(form_frame, weight=2)
        form_frame.columnconfigure(1, weight=1)

        self.s_vars = {
            "id": tk.StringVar(),
            "name": tk.StringVar(),
            "desc": tk.StringVar(),
            "channel": tk.StringVar(),
            "host": tk.StringVar(),
            "base": tk.StringVar(value=DEFAULT_PUBLIC_BASE),
        }

        fields = [
            ("Station ID (e.g. vaporwave):", "id"),
            ("Station Name:", "name"),
            ("Description:", "desc"),
            ("Rednet Channel (Optional):", "channel"),
            ("Host Label (Optional):", "host"),
            ("Public Base URL:", "base"),
        ]
        for row, (label, key) in enumerate(fields):
            ttk.Label(form_frame, text=label).grid(row=row, column=0, sticky=tk.W, padx=10, pady=5)
            ttk.Entry(form_frame, textvariable=self.s_vars[key]).grid(
                row=row, column=1, sticky=tk.EW, padx=10, pady=5
            )

        ttk.Button(form_frame, text="Create Station", command=self.create_station).grid(
            row=len(fields), column=1, pady=20, sticky=tk.E, padx=10
        )

    def build_playlist_tab(self):
        top_frame = ttk.Frame(self.tab_playlist)
        top_frame.pack(fill=tk.X, pady=5)
        ttk.Label(top_frame, text="Select Station:").pack(side=tk.LEFT, padx=5)
        self.cb_playlist_station = ttk.Combobox(top_frame, state="readonly", width=40)
        self.cb_playlist_station.pack(side=tk.LEFT, padx=5)
        self.cb_playlist_station.bind("<<ComboboxSelected>>", self.load_playlist_tracks)
        ttk.Button(top_frame, text="Uploader Settings", command=self.open_uploader_settings).pack(
            side=tk.RIGHT, padx=5
        )

        content = ttk.PanedWindow(self.tab_playlist, orient=tk.HORIZONTAL)
        content.pack(fill=tk.BOTH, expand=True)

        left_container = ttk.Frame(content)
        content.add(left_container, weight=1)

        list_frame = ttk.LabelFrame(left_container, text="Tracks in Playlist")
        list_frame.pack(fill=tk.BOTH, expand=True)

        self.track_tree = ttk.Treeview(list_frame, columns=("title", "artist", "dur"), show="headings")
        self.track_tree.heading("title", text="Title")
        self.track_tree.heading("artist", text="Artist")
        self.track_tree.heading("dur", text="Time")
        self.track_tree.column("dur", width=70, stretch=False)
        self.track_tree.pack(fill=tk.BOTH, expand=True, padx=5, pady=5)
        self.track_tree.bind("<<TreeviewSelect>>", self.on_track_select)

        btn_frame = ttk.Frame(left_container)
        btn_frame.pack(fill=tk.X, pady=5)
        ttk.Button(btn_frame, text="Delete Selected Track", command=self.delete_track).pack(
            side=tk.RIGHT, padx=5
        )

        right_container = ttk.Frame(content)
        content.add(right_container, weight=2)

        form_frame = ttk.LabelFrame(right_container, text="Track Details")
        form_frame.pack(fill=tk.X, expand=False)
        form_frame.columnconfigure(1, weight=1)

        self.t_vars = {
            "url_l": tk.StringVar(),
            "url_r": tk.StringVar(),
            "title": tk.StringVar(),
            "artist": tk.StringVar(),
            "dur": tk.StringVar(),
            "source": tk.StringVar(),
            "art": tk.StringVar(),
            "source_file": tk.StringVar(),
            "publish_target": tk.StringVar(value=self.studio_config["default_publish_target"]),
            "output_subfolder": tk.StringVar(value=self.studio_config["default_output_subfolder"]),
            "processing_normalize": tk.BooleanVar(value=self.studio_config["processing_normalize"]),
            "processing_tame_highs": tk.BooleanVar(value=self.studio_config["processing_tame_highs"]),
            "processing_lowpass_hz": tk.StringVar(value=str(self.studio_config["processing_lowpass_hz"])),
            "processing_dither_8bit": tk.BooleanVar(value=self.studio_config["processing_dither_8bit"]),
            "processing_limiter": tk.BooleanVar(value=self.studio_config["processing_limiter"]),
            "processing_limit": tk.StringVar(value=str(self.studio_config["processing_limit"])),
        }

        ttk.Label(form_frame, text="Playback URL Left (.dfpwm):").grid(
            row=0, column=0, sticky=tk.W, padx=10, pady=5
        )
        left_url_frame = ttk.Frame(form_frame)
        left_url_frame.grid(row=0, column=1, sticky=tk.EW, padx=10, pady=5)
        left_url_frame.columnconfigure(0, weight=1)
        ttk.Entry(left_url_frame, textvariable=self.t_vars["url_l"]).grid(row=0, column=0, sticky=tk.EW)
        ttk.Button(
            left_url_frame,
            text="Auto-Fill Metadata",
            command=lambda: self.auto_fill_track(self.t_vars),
        ).grid(row=0, column=1, padx=(6, 0))

        ttk.Label(form_frame, text="Playback URL Right (.dfpwm):").grid(
            row=1, column=0, sticky=tk.W, padx=10, pady=5
        )
        ttk.Entry(form_frame, textvariable=self.t_vars["url_r"]).grid(
            row=1, column=1, sticky=tk.EW, padx=10, pady=5
        )

        ttk.Label(form_frame, text="Source File:").grid(row=2, column=0, sticky=tk.W, padx=10, pady=5)
        source_frame = ttk.Frame(form_frame)
        source_frame.grid(row=2, column=1, sticky=tk.EW, padx=10, pady=5)
        source_frame.columnconfigure(0, weight=1)
        ttk.Entry(source_frame, textvariable=self.t_vars["source_file"]).grid(row=0, column=0, sticky=tk.EW)
        ttk.Button(source_frame, text="Browse...", command=self.browse_source_file).grid(
            row=0, column=1, padx=(6, 0)
        )

        ttk.Label(form_frame, text="Publishing Target:").grid(
            row=3, column=0, sticky=tk.W, padx=10, pady=5
        )
        publish_frame = ttk.Frame(form_frame)
        publish_frame.grid(row=3, column=1, sticky=tk.EW, padx=10, pady=5)
        publish_frame.columnconfigure(0, weight=1)
        publish_combo = ttk.Combobox(
            publish_frame,
            state="readonly",
            values=("Local", "Catbox", "File Garden"),
            textvariable=self.t_vars["publish_target"],
        )
        publish_combo.grid(row=0, column=0, sticky=tk.W)
        ttk.Button(publish_frame, text="Edit Upload Settings", command=self.open_uploader_settings).grid(
            row=0, column=1, padx=(6, 0)
        )

        ttk.Label(form_frame, text="Output Subfolder:").grid(
            row=4, column=0, sticky=tk.W, padx=10, pady=5
        )
        ttk.Entry(form_frame, textvariable=self.t_vars["output_subfolder"]).grid(
            row=4, column=1, sticky=tk.EW, padx=10, pady=5
        )

        processing_frame = ttk.LabelFrame(form_frame, text="Optional Audio Processing")
        processing_frame.grid(row=5, column=0, columnspan=2, sticky=tk.EW, padx=10, pady=8)
        processing_frame.columnconfigure(1, weight=1)
        processing_frame.columnconfigure(3, weight=1)

        ttk.Checkbutton(
            processing_frame, text="Normalize Loudness", variable=self.t_vars["processing_normalize"]
        ).grid(row=0, column=0, sticky=tk.W, padx=8, pady=4)
        ttk.Checkbutton(
            processing_frame, text="Tame Highs", variable=self.t_vars["processing_tame_highs"]
        ).grid(row=0, column=2, sticky=tk.W, padx=8, pady=4)
        ttk.Label(processing_frame, text="Lowpass Hz:").grid(row=0, column=4, sticky=tk.W, padx=(8, 4), pady=4)
        ttk.Entry(processing_frame, textvariable=self.t_vars["processing_lowpass_hz"], width=8).grid(
            row=0, column=5, sticky=tk.W, padx=(0, 8), pady=4
        )

        ttk.Checkbutton(
            processing_frame, text="8-bit Dither", variable=self.t_vars["processing_dither_8bit"]
        ).grid(row=1, column=0, sticky=tk.W, padx=8, pady=4)
        ttk.Checkbutton(
            processing_frame, text="Limiter", variable=self.t_vars["processing_limiter"]
        ).grid(row=1, column=2, sticky=tk.W, padx=8, pady=4)
        ttk.Label(processing_frame, text="Limiter Ceiling:").grid(
            row=1, column=4, sticky=tk.W, padx=(8, 4), pady=4
        )
        ttk.Entry(processing_frame, textvariable=self.t_vars["processing_limit"], width=8).grid(
            row=1, column=5, sticky=tk.W, padx=(0, 8), pady=4
        )

        fields = [
            ("Title:", "title"),
            ("Artist:", "artist"),
            ("Duration (MM:SS or Secs):", "dur"),
            ("Original Source URL (Opt):", "source"),
            ("Cover Art URL (Opt):", "art"),
        ]
        for index, (label, key) in enumerate(fields, start=6):
            ttk.Label(form_frame, text=label).grid(row=index, column=0, sticky=tk.W, padx=10, pady=5)
            ttk.Entry(form_frame, textvariable=self.t_vars[key]).grid(
                row=index, column=1, sticky=tk.EW, padx=10, pady=5
            )

        action_frame = ttk.Frame(form_frame)
        action_frame.grid(row=11, column=0, columnspan=2, pady=16, sticky=tk.EW, padx=10)
        ttk.Button(action_frame, text="Clear Form", command=self.clear_form).pack(side=tk.LEFT, padx=5)
        ttk.Button(
            action_frame, text="Convert + Fill Current Track", command=self.convert_and_fill_current_track
        ).pack(side=tk.LEFT, padx=5)
        ttk.Button(action_frame, text="Batch Convert Folder", command=self.batch_convert_folder).pack(
            side=tk.LEFT, padx=5
        )
        ttk.Button(
            action_frame, text="Fill URLs from File Garden", command=self.fill_urls_from_filegarden
        ).pack(side=tk.LEFT, padx=5)
        ttk.Button(
            action_frame, text="Auto-Fill Playlist from Folder", command=self.autofill_playlist_from_folder
        ).pack(side=tk.LEFT, padx=5)
        ttk.Button(action_frame, text="Update Selected Track", command=self.update_track).pack(
            side=tk.RIGHT, padx=5
        )
        ttk.Button(action_frame, text="Add as New Track", command=self.add_track_to_playlist).pack(
            side=tk.RIGHT, padx=5
        )

        log_frame = ttk.LabelFrame(right_container, text="Conversion / Upload Log")
        log_frame.pack(fill=tk.BOTH, expand=True, pady=(10, 0))
        self.playlist_log = scrolledtext.ScrolledText(log_frame, height=14, wrap=tk.WORD, state=tk.DISABLED)
        self.playlist_log.pack(fill=tk.BOTH, expand=True, padx=5, pady=5)

    def build_submit_tab(self):
        content = ttk.PanedWindow(self.tab_submit, orient=tk.HORIZONTAL)
        content.pack(fill=tk.BOTH, expand=True)

        left = ttk.Frame(content)
        content.add(left, weight=1)

        s_frame = ttk.LabelFrame(left, text="1. Station Info")
        s_frame.pack(fill=tk.X, padx=5, pady=5)
        s_frame.columnconfigure(1, weight=1)
        self.sub_s_vars = {"id": tk.StringVar(), "name": tk.StringVar(), "desc": tk.StringVar()}
        ttk.Label(s_frame, text="Station ID:").grid(row=0, column=0, sticky=tk.W, padx=5, pady=2)
        ttk.Entry(s_frame, textvariable=self.sub_s_vars["id"]).grid(
            row=0, column=1, sticky=tk.EW, padx=5, pady=2
        )
        ttk.Label(s_frame, text="Station Name:").grid(row=1, column=0, sticky=tk.W, padx=5, pady=2)
        ttk.Entry(s_frame, textvariable=self.sub_s_vars["name"]).grid(
            row=1, column=1, sticky=tk.EW, padx=5, pady=2
        )
        ttk.Label(s_frame, text="Description:").grid(row=2, column=0, sticky=tk.W, padx=5, pady=2)
        ttk.Entry(s_frame, textvariable=self.sub_s_vars["desc"]).grid(
            row=2, column=1, sticky=tk.EW, padx=5, pady=2
        )

        l_frame = ttk.LabelFrame(left, text="2. Added Tracks")
        l_frame.pack(fill=tk.BOTH, expand=True, padx=5, pady=5)
        self.sub_tree = ttk.Treeview(l_frame, columns=("title", "dur"), show="headings")
        self.sub_tree.heading("title", text="Title")
        self.sub_tree.heading("dur", text="Time")
        self.sub_tree.column("dur", width=60, stretch=False)
        self.sub_tree.pack(fill=tk.BOTH, expand=True, padx=5, pady=5)

        ttk.Button(left, text="Export Submission JSON...", command=self.export_submission).pack(pady=10)

        right = ttk.LabelFrame(content, text="3. Add Track to Submission")
        content.add(right, weight=2)
        right.columnconfigure(1, weight=1)

        self.sub_t_vars = {
            "url": tk.StringVar(),
            "title": tk.StringVar(),
            "artist": tk.StringVar(),
            "dur": tk.StringVar(),
            "source": tk.StringVar(),
            "art": tk.StringVar(),
        }

        url_frame = ttk.Frame(right)
        url_frame.grid(row=0, column=0, columnspan=2, sticky=tk.EW, padx=10, pady=5)
        url_frame.columnconfigure(1, weight=1)
        ttk.Label(url_frame, text="Playback URL:").grid(row=0, column=0, sticky=tk.W)
        ttk.Entry(url_frame, textvariable=self.sub_t_vars["url"]).grid(row=0, column=1, sticky=tk.EW, padx=5)
        ttk.Button(
            url_frame,
            text="Auto-Fill",
            command=lambda: self.auto_fill_track(self.sub_t_vars),
        ).grid(row=0, column=2)

        fields = [
            ("Title:", "title"),
            ("Artist:", "artist"),
            ("Duration (MM:SS):", "dur"),
            ("Source URL:", "source"),
            ("Art URL:", "art"),
        ]
        for row, (label, key) in enumerate(fields, start=1):
            ttk.Label(right, text=label).grid(row=row, column=0, sticky=tk.W, padx=10, pady=5)
            ttk.Entry(right, textvariable=self.sub_t_vars[key]).grid(
                row=row, column=1, sticky=tk.EW, padx=10, pady=5
            )

        ttk.Button(right, text="Add Track", command=self.add_track_to_submission).grid(
            row=len(fields) + 1, column=1, pady=20, sticky=tk.E, padx=10
        )

    # --- GENERAL HELPERS ---

    def append_log(self, message: str):
        timestamp = datetime.now().strftime("%H:%M:%S")
        self.playlist_log.config(state=tk.NORMAL)
        self.playlist_log.insert(tk.END, f"[{timestamp}] {message}\n")
        self.playlist_log.see(tk.END)
        self.playlist_log.config(state=tk.DISABLED)
        self.update_idletasks()

    def browse_workspace(self):
        folder = filedialog.askdirectory(title="Select Rednet Radio Root or Site Folder")
        if folder:
            self.load_workspace(Path(folder))

    def browse_source_file(self):
        path = filedialog.askopenfilename(title="Select Source Audio/Video File")
        if path:
            self.t_vars["source_file"].set(path)
            self.auto_fill_track(self.t_vars)

    def load_workspace(self, path: Path):
        self.root_dir = path
        self.stations_file = path / "stations.json"
        self.playlists_dir = path / "playlists"
        self.studio_config_path = path / STUDIO_CONFIG_NAME
        self.studio_config = load_studio_config(self.studio_config_path)
        self.lbl_workspace.config(text=str(path))

        if hasattr(self, "t_vars"):
            self.t_vars["publish_target"].set(self.studio_config["default_publish_target"])
            self.t_vars["output_subfolder"].set(self.studio_config["default_output_subfolder"])
            self.t_vars["processing_normalize"].set(self.studio_config["processing_normalize"])
            self.t_vars["processing_tame_highs"].set(self.studio_config["processing_tame_highs"])
            self.t_vars["processing_lowpass_hz"].set(str(self.studio_config["processing_lowpass_hz"]))
            self.t_vars["processing_dither_8bit"].set(self.studio_config["processing_dither_8bit"])
            self.t_vars["processing_limiter"].set(self.studio_config["processing_limiter"])
            self.t_vars["processing_limit"].set(str(self.studio_config["processing_limit"]))

        if not self.stations_file.exists():
            if messagebox.askyesno(
                "Workspace Initialization",
                f"No stations.json found in:\n{path}\n\nWould you like to initialize this folder as a Workspace?",
            ):
                save_json(self.stations_file, {"stations": []})
                self.playlists_dir.mkdir(exist_ok=True)
            else:
                self.station_tree.delete(*self.station_tree.get_children())
                return

        self.refresh_station_list()
        self.append_log(f"Workspace loaded: {path}")

    def save_studio_config(self):
        if self.studio_config_path is None:
            return
        save_json(self.studio_config_path, self.studio_config)

    def open_uploader_settings(self):
        dialog = tk.Toplevel(self)
        dialog.title("Uploader Settings")
        dialog.transient(self)
        dialog.grab_set()
        dialog.columnconfigure(1, weight=1)

        vars_map = {
            "filegarden_user_id": tk.StringVar(value=self.studio_config.get("filegarden_user_id", "")),
            "filegarden_auth_cookie": tk.StringVar(value=self.studio_config.get("filegarden_auth_cookie", "")),
            "filegarden_base_url": tk.StringVar(value=self.studio_config.get("filegarden_base_url", "")),
            "catbox_userhash": tk.StringVar(value=self.studio_config.get("catbox_userhash", "")),
            "local_dfpwm_folder": tk.StringVar(value=self.studio_config.get("local_dfpwm_folder", "")),
            "default_publish_target": tk.StringVar(
                value=self.studio_config.get("default_publish_target", "Local")
            ),
            "default_output_subfolder": tk.StringVar(
                value=self.studio_config.get("default_output_subfolder", "audio")
            ),
            "processing_normalize": tk.BooleanVar(value=self.studio_config.get("processing_normalize", False)),
            "processing_tame_highs": tk.BooleanVar(value=self.studio_config.get("processing_tame_highs", False)),
            "processing_lowpass_hz": tk.StringVar(
                value=str(self.studio_config.get("processing_lowpass_hz", DEFAULT_LOWPASS_HZ))
            ),
            "processing_dither_8bit": tk.BooleanVar(
                value=self.studio_config.get("processing_dither_8bit", False)
            ),
            "processing_limiter": tk.BooleanVar(value=self.studio_config.get("processing_limiter", False)),
            "processing_limit": tk.StringVar(
                value=str(self.studio_config.get("processing_limit", DEFAULT_LIMIT))
            ),
        }

        labels = [
            ("File Garden User ID:", "filegarden_user_id"),
            ("File Garden Auth Cookie:", "filegarden_auth_cookie"),
            ("File Garden Base Folder URL:", "filegarden_base_url"),
            ("Local DFPWM Folder:", "local_dfpwm_folder"),
            ("Catbox Userhash (Optional):", "catbox_userhash"),
            ("Default Output Subfolder:", "default_output_subfolder"),
        ]
        for row, (label, key) in enumerate(labels):
            ttk.Label(dialog, text=label).grid(row=row, column=0, sticky=tk.W, padx=10, pady=6)
            ttk.Entry(dialog, textvariable=vars_map[key], width=60).grid(
                row=row, column=1, sticky=tk.EW, padx=10, pady=6
            )

        ttk.Label(dialog, text="Default Publishing Target:").grid(
            row=len(labels), column=0, sticky=tk.W, padx=10, pady=6
        )
        ttk.Combobox(
            dialog,
            state="readonly",
            values=("Local", "Catbox", "File Garden"),
            textvariable=vars_map["default_publish_target"],
        ).grid(row=len(labels), column=1, sticky=tk.W, padx=10, pady=6)

        ttk.Checkbutton(
            dialog, text="Default Normalize Loudness", variable=vars_map["processing_normalize"]
        ).grid(row=len(labels) + 1, column=0, sticky=tk.W, padx=10, pady=4)
        ttk.Checkbutton(
            dialog, text="Default Tame Highs", variable=vars_map["processing_tame_highs"]
        ).grid(row=len(labels) + 1, column=1, sticky=tk.W, padx=10, pady=4)
        ttk.Checkbutton(
            dialog, text="Default 8-bit Dither", variable=vars_map["processing_dither_8bit"]
        ).grid(row=len(labels) + 2, column=0, sticky=tk.W, padx=10, pady=4)
        ttk.Checkbutton(
            dialog, text="Default Limiter", variable=vars_map["processing_limiter"]
        ).grid(row=len(labels) + 2, column=1, sticky=tk.W, padx=10, pady=4)
        ttk.Label(dialog, text="Default Lowpass Hz:").grid(
            row=len(labels) + 3, column=0, sticky=tk.W, padx=10, pady=6
        )
        ttk.Entry(dialog, textvariable=vars_map["processing_lowpass_hz"], width=16).grid(
            row=len(labels) + 3, column=1, sticky=tk.W, padx=10, pady=6
        )
        ttk.Label(dialog, text="Default Limiter Ceiling:").grid(
            row=len(labels) + 4, column=0, sticky=tk.W, padx=10, pady=6
        )
        ttk.Entry(dialog, textvariable=vars_map["processing_limit"], width=16).grid(
            row=len(labels) + 4, column=1, sticky=tk.W, padx=10, pady=6
        )

        def save_and_close():
            for key, var in vars_map.items():
                value = var.get()
                if isinstance(value, str):
                    value = value.strip()
                self.studio_config[key] = value
            self.save_studio_config()
            self.t_vars["publish_target"].set(self.studio_config["default_publish_target"])
            self.t_vars["output_subfolder"].set(self.studio_config["default_output_subfolder"])
            self.t_vars["processing_normalize"].set(self.studio_config["processing_normalize"])
            self.t_vars["processing_tame_highs"].set(self.studio_config["processing_tame_highs"])
            self.t_vars["processing_lowpass_hz"].set(str(self.studio_config["processing_lowpass_hz"]))
            self.t_vars["processing_dither_8bit"].set(self.studio_config["processing_dither_8bit"])
            self.t_vars["processing_limiter"].set(self.studio_config["processing_limiter"])
            self.t_vars["processing_limit"].set(str(self.studio_config["processing_limit"]))
            self.append_log("Saved uploader settings.")
            dialog.destroy()

        button_frame = ttk.Frame(dialog)
        button_frame.grid(row=len(labels) + 5, column=0, columnspan=2, sticky=tk.E, padx=10, pady=12)
        ttk.Button(button_frame, text="Cancel", command=dialog.destroy).pack(side=tk.RIGHT, padx=5)
        ttk.Button(button_frame, text="Save", command=save_and_close).pack(side=tk.RIGHT, padx=5)

    def refresh_station_list(self):
        self.station_tree.delete(*self.station_tree.get_children())
        doc = load_json(self.stations_file)
        stations = doc.get("stations", [])

        cb_values = []
        for station in stations:
            station_id = station.get("station_id", "unknown")
            name = station.get("name", "Unnamed")
            self.station_tree.insert("", tk.END, values=(f"{name} ({station_id})",))
            cb_values.append(station_id)

        self.cb_playlist_station["values"] = cb_values
        if cb_values and self.cb_playlist_station.get() not in cb_values:
            self.cb_playlist_station.current(0)
            self.load_playlist_tracks()

    def get_station_by_id(self, station_id: str) -> dict:
        doc = load_json(self.stations_file)
        for station in doc.get("stations", []):
            if station.get("station_id") == station_id:
                return station
        return {}

    def get_playlist_doc_and_target(self, station_id: str):
        path = self.get_playlist_path(station_id)
        doc = load_json(path)
        if isinstance(doc, list):
            container = {"name": f"{station_id} Playlist", "version": "1", "tracks": doc}
            return path, container, container
        if "playlist" in doc and isinstance(doc["playlist"], dict):
            return path, doc, doc["playlist"]
        if not isinstance(doc, dict):
            doc = {}
        doc.setdefault("name", f"{station_id} Playlist")
        doc.setdefault("version", "1")
        doc.setdefault("tracks", [])
        return path, doc, doc

    def get_playlist_path(self, sid: str) -> Path:
        doc = load_json(self.stations_file)
        for station in doc.get("stations", []):
            if station.get("station_id") == sid:
                url = station.get("playlist_url", "")
                if url:
                    filename = unquote(urlparse(url).path.split("/")[-1])
                    if filename:
                        if not filename.endswith(".json"):
                            filename += ".json"
                        return self.playlists_dir / filename
        return self.playlists_dir / f"{sid}.json"

    def get_station_public_base(self, station_id: str) -> str:
        station = self.get_station_by_id(station_id)
        playlist_url = station.get("playlist_url", "")
        if playlist_url:
            parsed = urlparse(playlist_url)
            if parsed.scheme and parsed.netloc:
                marker = "/playlists/"
                if marker in parsed.path:
                    prefix = parsed.path.split(marker, 1)[0].rstrip("/")
                    return f"{parsed.scheme}://{parsed.netloc}{prefix}"
                return f"{parsed.scheme}://{parsed.netloc}"
        return DEFAULT_PUBLIC_BASE

    def auto_fill_track(self, var_dict):
        primary_key = "url_l" if "url_l" in var_dict else "url"
        source_file = var_dict["source_file"].get().strip() if "source_file" in var_dict else ""
        url = normalize_github_url(var_dict[primary_key].get().strip()) if primary_key in var_dict else ""
        if url:
            var_dict[primary_key].set(url)

        name_source = ""
        if url:
            name_source = unquote(url.split("/")[-1])
        elif source_file:
            name_source = Path(source_file).name
        else:
            messagebox.showwarning("Warning", "Enter a playback URL or pick a source file first.")
            return

        for suffix in ("_L.dfpwm", "_R.dfpwm", ".dfpwm"):
            if name_source.endswith(suffix):
                name_source = name_source[: -len(suffix)]
                break

        if " - " in name_source:
            artist, title = name_source.split(" - ", 1)
            if not var_dict["artist"].get():
                var_dict["artist"].set(artist.strip())
            if not var_dict["title"].get():
                var_dict["title"].set(title.strip())
        elif not var_dict["title"].get():
            var_dict["title"].set(name_source.replace("_", " ").strip())

    def fill_urls_from_filegarden(self):
        """Build File Garden playback URLs for the current track from the configured base folder URL.

        Priority for determining the file stem:
          1. Source file field (most reliable — uses the actual local filename).
          2. Strip _L/_R suffix from an existing left URL (useful when editing an existing track).

        The stem is then URL-encoded and appended to the base folder URL as
        ``{stem}_L.dfpwm`` and ``{stem}_R.dfpwm``, matching the naming convention
        produced by the batch converter (e.g.
        ``https://file.garden/USER/FOLDER/01%20-%20Song%20Title_L.dfpwm``).
        """
        base_url = self.studio_config.get("filegarden_base_url", "").strip().rstrip("/")
        if not base_url:
            messagebox.showerror(
                "File Garden Auto-Fill",
                "No File Garden Base Folder URL is configured.\n\n"
                "Open Uploader Settings and fill in the 'File Garden Base Folder URL' field\n"
                "(e.g. https://file.garden/USER_ID/my_folder).",
            )
            return

        # --- Determine the file stem ---
        stem = ""
        source_file = self.t_vars["source_file"].get().strip()
        if source_file:
            # Use the source file name before the extension (same stem the converter uses)
            stem = Path(source_file).stem
        else:
            # Fall back: strip channel suffix from an existing URL
            existing_url = self.t_vars["url_l"].get().strip()
            if existing_url:
                filename = unquote(existing_url.split("/")[-1])
                for suffix in ("_L.dfpwm", "_R.dfpwm", ".dfpwm"):
                    if filename.lower().endswith(suffix.lower()):
                        stem = filename[: -len(suffix)]
                        break
                if not stem:
                    stem = Path(filename).stem

        if not stem:
            messagebox.showerror(
                "File Garden Auto-Fill",
                "Cannot determine the file name.\n\n"
                "Either browse a local source file or paste a partial playback URL first.",
            )
            return

        left_name = f"{stem}_L.dfpwm"
        right_name = f"{stem}_R.dfpwm"
        left_url = base_url + "/" + quote(left_name)
        right_url = base_url + "/" + quote(right_name)

        self.t_vars["url_l"].set(left_url)
        self.t_vars["url_r"].set(right_url)
        self.append_log(f"File Garden URLs filled for '{stem}'.")

        # Also run the standard metadata auto-fill so title/artist are populated from the stem
        self.auto_fill_track(self.t_vars)

    def autofill_playlist_from_folder(self):
        """Scan a local DFPWM folder and bulk-add every *_L.dfpwm file as a track.

        For each ``{stem}_L.dfpwm`` found:
        - Title / artist are parsed from the stem using the ``Artist - Title`` convention.
        - Playback URLs are built from the configured File Garden base folder URL (optional —
          the track is still added without URLs if the base is not set, so you can paste
          them in later).
        - Duration is probed via ffprobe if available; falls back to 0 so the track is
          always inserted (you can edit durations individually afterwards).

        The folder choice is remembered in ``radio_studio.local.json`` so you don't have
        to re-select it every time.
        """
        station_id = self.cb_playlist_station.get()
        if not station_id:
            messagebox.showerror("Error", "Select a station first.")
            return

        # --- Resolve the DFPWM folder ---
        folder_str = self.studio_config.get("local_dfpwm_folder", "").strip()
        if folder_str and Path(folder_str).is_dir():
            dfpwm_folder = Path(folder_str)
        else:
            chosen = filedialog.askdirectory(title="Select Local DFPWM Folder")
            if not chosen:
                return
            dfpwm_folder = Path(chosen)
            self.studio_config["local_dfpwm_folder"] = str(dfpwm_folder)
            self.save_studio_config()

        # --- Scan for _L.dfpwm files (sorted = track order) ---
        left_files = sorted(dfpwm_folder.glob("*_L.dfpwm"))
        if not left_files:
            messagebox.showinfo(
                "Auto-Fill Playlist",
                f"No *_L.dfpwm files found in:\n{dfpwm_folder}",
            )
            return

        base_url = self.studio_config.get("filegarden_base_url", "").strip().rstrip("/")

        if not messagebox.askyesno(
            "Auto-Fill Playlist",
            f"Found {len(left_files)} track(s) in:\n{dfpwm_folder}\n\n"
            f"{'File Garden URLs will be generated from:\n' + base_url if base_url else 'No File Garden base URL configured — tracks will be added without playback URLs.'}\n\n"
            "Add all tracks to the playlist now?",
        ):
            return

        # --- Load playlist once, bulk-append, save once ---
        path, doc, target = self.get_playlist_doc_and_target(station_id)
        tracks = target.setdefault("tracks", [])

        highest = 0
        for track in tracks:
            track_id = str(track.get("id", ""))
            if track_id.startswith("track_"):
                try:
                    highest = max(highest, int(track_id.split("_", 1)[1]))
                except ValueError:
                    pass

        added = 0
        skipped = 0
        for left_file in left_files:
            stem = left_file.name[: -len("_L.dfpwm")]
            right_file = left_file.with_name(f"{stem}_R.dfpwm")

            # Parse artist / title from stem
            if " - " in stem:
                raw_artist, raw_title = stem.split(" - ", 1)
            else:
                raw_artist = ""
                raw_title = stem.replace("_", " ")

            # Probe duration (best-effort)
            duration = 0
            if self.ffmpeg_available or shutil.which("ffprobe"):
                try:
                    result = subprocess.run(
                        [
                            "ffprobe",
                            "-v", "error",
                            "-select_streams", "a:0",
                            "-show_entries", "format=duration",
                            "-of", "default=noprint_wrappers=1:nokey=1",
                            str(left_file),
                        ],
                        capture_output=True,
                        text=True,
                    )
                    raw_dur = result.stdout.strip()
                    if raw_dur:
                        duration = max(0, int(float(raw_dur)))
                except Exception:
                    pass

            # Build the track dict
            track: dict = {
                "id": f"track_{highest + added + 1:02d}",
                "title": raw_title.strip(),
                "artist": raw_artist.strip(),
                "duration": duration,
            }
            if base_url:
                track["playback_url"] = base_url + "/" + quote(f"{stem}_L.dfpwm")
                if right_file.exists() or base_url:
                    track["playback_url_r"] = base_url + "/" + quote(f"{stem}_R.dfpwm")

            tracks.append(track)
            added += 1
            self.append_log(
                f"Queued: '{raw_title.strip()}'"
                + (f" by {raw_artist.strip()}" if raw_artist else "")
                + (f" ({format_duration(duration)})" if duration else " (duration unknown)")
            )

        target["version"] = bump_version(target.get("version", "0"))
        save_json(path, doc)
        self.load_playlist_tracks()

        summary = f"Auto-fill complete: {added} track(s) added, {skipped} skipped."
        self.append_log(summary)
        messagebox.showinfo("Auto-Fill Playlist", summary)

    def create_station(self):
        if not self.stations_file or not self.stations_file.exists():
            messagebox.showerror("Error", "Workspace not initialized.")
            return

        station_id = self.s_vars["id"].get().strip()
        name = self.s_vars["name"].get().strip()
        if not station_id or not name:
            messagebox.showerror("Error", "Station ID and Name are required.")
            return

        doc = load_json(self.stations_file)
        stations = doc.setdefault("stations", [])
        if any(station.get("station_id") == station_id for station in stations):
            messagebox.showerror("Error", "Station ID already exists!")
            return

        base = self.s_vars["base"].get().strip().rstrip("/")
        station = {
            "station_id": station_id,
            "name": name,
            "description": self.s_vars["desc"].get().strip(),
            "playlist_url": f"{base}/playlists/{station_id}.json",
            "rednet_channel": self.s_vars["channel"].get().strip()
            or f"rednet_radio_v1:station:{station_id}",
            "host_label": self.s_vars["host"].get().strip(),
        }
        stations.append(station)
        save_json(self.stations_file, doc)

        playlist_doc = {"name": f"{name} Playlist", "version": "1", "tracks": []}
        save_json(self.playlists_dir / f"{station_id}.json", playlist_doc)

        messagebox.showinfo("Success", f"Station '{name}' created successfully!")
        self.refresh_station_list()
        for var in self.s_vars.values():
            var.set("")
        self.s_vars["base"].set(DEFAULT_PUBLIC_BASE)

    def on_tab_change(self, event):
        if self.notebook.index("current") == 1:
            self.refresh_station_list()

    # --- FFMPEG / CONVERSION HELPERS ---

    def ensure_ffmpeg_tools(self) -> bool:
        if self.ffmpeg_checked:
            if not self.ffmpeg_available:
                messagebox.showerror("FFmpeg Missing", "ffmpeg and ffprobe are required for conversion.")
            return self.ffmpeg_available

        ffmpeg_path = shutil.which("ffmpeg")
        ffprobe_path = shutil.which("ffprobe")
        self.ffmpeg_checked = True
        self.ffmpeg_available = bool(ffmpeg_path and ffprobe_path)
        if not self.ffmpeg_available:
            messagebox.showerror("FFmpeg Missing", "ffmpeg and ffprobe must be installed and available on PATH.")
            self.append_log("Conversion blocked: ffmpeg or ffprobe is missing.")
        return self.ffmpeg_available

    def run_process(self, cmd: list[str]) -> subprocess.CompletedProcess:
        return subprocess.run(cmd, capture_output=True, text=True, check=True)

    def probe_channel_count(self, source_path: Path) -> int:
        result = self.run_process(
            [
                "ffprobe",
                "-v",
                "error",
                "-select_streams",
                "a:0",
                "-show_entries",
                "stream=channels",
                "-of",
                "default=noprint_wrappers=1:nokey=1",
                str(source_path),
            ]
        )
        value = result.stdout.strip()
        if not value:
            raise RuntimeError(f"No readable audio stream found in '{source_path.name}'.")
        return max(1, int(value))

    def can_probe_audio(self, source_path: Path) -> bool:
        try:
            self.probe_channel_count(source_path)
            return True
        except Exception:
            return False

    def build_pan_filters(self, channel_count: int) -> tuple[str, str]:
        if channel_count <= 1:
            return "pan=mono|c0=c0", "pan=mono|c0=c0"
        return "pan=mono|c0=c0", "pan=mono|c0=c1"

    def get_processing_options(self) -> dict:
        def parse_int(value, default):
            try:
                return int(str(value).strip())
            except (TypeError, ValueError):
                return default

        def parse_float(value, default):
            try:
                return float(str(value).strip())
            except (TypeError, ValueError):
                return default

        options = {
            "normalize": bool(self.t_vars["processing_normalize"].get()),
            "tame_highs": bool(self.t_vars["processing_tame_highs"].get()),
            "lowpass_hz": max(1000, parse_int(self.t_vars["processing_lowpass_hz"].get(), DEFAULT_LOWPASS_HZ)),
            "dither_8bit": bool(self.t_vars["processing_dither_8bit"].get()),
            "limiter": bool(self.t_vars["processing_limiter"].get()),
            "limit": min(1.0, max(0.0625, parse_float(self.t_vars["processing_limit"].get(), DEFAULT_LIMIT))),
        }
        return options

    def persist_processing_defaults_from_form(self):
        options = self.get_processing_options()
        self.studio_config["processing_normalize"] = options["normalize"]
        self.studio_config["processing_tame_highs"] = options["tame_highs"]
        self.studio_config["processing_lowpass_hz"] = options["lowpass_hz"]
        self.studio_config["processing_dither_8bit"] = options["dither_8bit"]
        self.studio_config["processing_limiter"] = options["limiter"]
        self.studio_config["processing_limit"] = options["limit"]
        self.save_studio_config()

    def build_filter_complex(self, channel_count: int, processing: dict) -> str:
        left_pan, right_pan = self.build_pan_filters(channel_count)

        pre_filters = []
        if processing["normalize"]:
            pre_filters.append("loudnorm=I=-18:LRA=11:TP=-1.5")
        if processing["tame_highs"]:
            pre_filters.append(f"lowpass=f={processing['lowpass_hz']}")
        if processing["limiter"]:
            pre_filters.append(f"alimiter=limit={processing['limit']:.4f}:level=false")

        head = ",".join(pre_filters) if pre_filters else "anull"
        resample = f"aresample={DEFAULT_SAMPLE_RATE}"
        if processing["dither_8bit"]:
            resample = f"aresample={DEFAULT_SAMPLE_RATE}:osf=u8:dither_method=triangular_hp"

        left_chain = f"{left_pan},{resample},aformat=sample_fmts=s16[left]"
        right_chain = f"{right_pan},{resample},aformat=sample_fmts=s16[right]"
        return f"[0:a:0]{head},asplit=2[l][r];[l]{left_chain};[r]{right_chain}"

    def convert_media_to_pair(self, source_path: Path, left_output: Path, right_output: Path, processing=None):
        processing = processing or self.get_processing_options()
        channel_count = self.probe_channel_count(source_path)
        filter_complex = self.build_filter_complex(channel_count, processing)
        left_output.parent.mkdir(parents=True, exist_ok=True)
        right_output.parent.mkdir(parents=True, exist_ok=True)
        cmd = [
            "ffmpeg",
            "-hide_banner",
            "-loglevel",
            "error",
            "-y",
            "-i",
            str(source_path),
            "-filter_complex",
            filter_complex,
            "-map",
            "[left]",
            "-c:a",
            "dfpwm",
            str(left_output),
            "-map",
            "[right]",
            "-c:a",
            "dfpwm",
            str(right_output),
        ]
        self.run_process(cmd)

    def convert_source_to_temp_pair(self, source_path: Path) -> tuple[Path, Path, tempfile.TemporaryDirectory]:
        temp_dir = tempfile.TemporaryDirectory(prefix="rednet_radio_stereo_")
        temp_root = Path(temp_dir.name)
        left_output = temp_root / f"{source_path.stem}_L.dfpwm"
        right_output = temp_root / f"{source_path.stem}_R.dfpwm"
        self.convert_media_to_pair(source_path, left_output, right_output, self.get_processing_options())
        return left_output, right_output, temp_dir

    # --- PUBLISHING HELPERS ---

    def save_local_pair(self, left_temp: Path, right_temp: Path, source_path: Path) -> tuple[str, str]:
        station_id = self.cb_playlist_station.get().strip()
        if not station_id:
            raise RuntimeError("Select a station first so the local URLs can be generated.")

        output_subfolder = (self.t_vars["output_subfolder"].get().strip() or "audio").strip("/\\")
        self.studio_config["default_output_subfolder"] = output_subfolder
        self.save_studio_config()

        output_root = self.root_dir / output_subfolder
        output_root.mkdir(parents=True, exist_ok=True)

        left_name = f"{source_path.stem}_L.dfpwm"
        right_name = f"{source_path.stem}_R.dfpwm"
        left_final = output_root / left_name
        right_final = output_root / right_name
        shutil.copyfile(left_temp, left_final)
        shutil.copyfile(right_temp, right_final)

        base_url = self.get_station_public_base(station_id)
        left_url = encode_url_from_parts(base_url, Path(output_subfolder) / left_name)
        right_url = encode_url_from_parts(base_url, Path(output_subfolder) / right_name)
        return left_url, right_url

    def build_multipart_payload(self, fields: dict[str, str], file_field: str, file_path: Path):
        boundary = f"----RednetRadioStudio{datetime.now().timestamp():.0f}"
        body = bytearray()
        for key, value in fields.items():
            body.extend(f"--{boundary}\r\n".encode("utf-8"))
            body.extend(f'Content-Disposition: form-data; name="{key}"\r\n\r\n'.encode("utf-8"))
            body.extend(value.encode("utf-8"))
            body.extend(b"\r\n")
        body.extend(f"--{boundary}\r\n".encode("utf-8"))
        body.extend(
            (
                f'Content-Disposition: form-data; name="{file_field}"; filename="{file_path.name}"\r\n'
                "Content-Type: application/octet-stream\r\n\r\n"
            ).encode("utf-8")
        )
        body.extend(file_path.read_bytes())
        body.extend(b"\r\n")
        body.extend(f"--{boundary}--\r\n".encode("utf-8"))
        return boundary, bytes(body)

    def upload_to_catbox(self, file_path: Path) -> str:
        fields = {"reqtype": "fileupload"}
        userhash = self.studio_config.get("catbox_userhash", "").strip()
        if userhash:
            fields["userhash"] = userhash
        boundary, payload = self.build_multipart_payload(fields, "fileToUpload", file_path)
        request = Request(
            CATBOX_API_URL,
            data=payload,
            headers={"Content-Type": f"multipart/form-data; boundary={boundary}"},
            method="POST",
        )
        with urlopen(request) as response:
            body = response.read().decode("utf-8", errors="replace").strip()
        if not body.startswith("http"):
            raise RuntimeError(f"Unexpected Catbox response: {body}")
        return body

    def upload_to_file_garden(self, file_path: Path) -> str:
        user_id = self.studio_config.get("filegarden_user_id", "").strip()
        auth_cookie = self.studio_config.get("filegarden_auth_cookie", "").strip()
        if not user_id or not auth_cookie:
            raise RuntimeError("File Garden credentials are missing. Open Uploader Settings first.")

        x_data = quote(json.dumps({"parent": None, "name": file_path.name}, separators=(",", ":")), safe="")
        request = Request(
            FILE_GARDEN_UPLOAD_URL.format(user_id=user_id),
            data=file_path.read_bytes(),
            headers={
                "Cookie": f"auth={auth_cookie}",
                "Content-Type": "application/octet-stream",
                "X-Data": x_data,
            },
            method="POST",
        )

        try:
            with urlopen(request) as response:
                raw_body = response.read().decode("utf-8", errors="replace")
        except HTTPError as exc:
            body = exc.read().decode("utf-8", errors="replace")
            raise RuntimeError(f"File Garden upload failed: HTTP {exc.code} - {body}") from exc
        except URLError as exc:
            raise RuntimeError(f"File Garden upload failed: {exc}") from exc

        try:
            payload = json.loads(raw_body)
        except json.JSONDecodeError as exc:
            raise RuntimeError(f"Unexpected File Garden response: {raw_body}") from exc

        try:
            item_path = payload["items"][0]["path"].lstrip("/")
        except (KeyError, IndexError, TypeError) as exc:
            raise RuntimeError(f"Unexpected File Garden response shape: {raw_body}") from exc

        return FILE_GARDEN_PUBLIC_URL.format(user_id=user_id, path=item_path)

    def publish_generated_pair(self, left_temp: Path, right_temp: Path, source_path: Path) -> tuple[str, str]:
        target = self.t_vars["publish_target"].get().strip() or "Local"
        self.studio_config["default_publish_target"] = target
        self.save_studio_config()

        if target == "Local":
            return self.save_local_pair(left_temp, right_temp, source_path)

        if target == "Catbox":
            self.append_log("Uploading left channel to Catbox...")
            left_url = self.upload_to_catbox(left_temp)
            self.append_log("Uploading right channel to Catbox...")
            right_url = self.upload_to_catbox(right_temp)
            return left_url, right_url

        if target == "File Garden":
            self.append_log("Uploading left channel to File Garden...")
            left_url = self.upload_to_file_garden(left_temp)
            self.append_log("Uploading right channel to File Garden...")
            right_url = self.upload_to_file_garden(right_temp)
            return left_url, right_url

        raise RuntimeError(f"Unknown publishing target: {target}")

    # --- TRACK EDITOR LOGIC ---

    def clear_form(self):
        self.editing_track_id = None
        for key in ("url_l", "url_r", "title", "artist", "dur", "source", "art", "source_file"):
            self.t_vars[key].set("")
        for item in self.track_tree.selection():
            self.track_tree.selection_remove(item)

    def load_playlist_tracks(self, event=None):
        self.clear_form()
        self.track_tree.delete(*self.track_tree.get_children())
        station_id = self.cb_playlist_station.get()
        if not station_id:
            return

        _, _, target = self.get_playlist_doc_and_target(station_id)
        tracks = target.get("tracks", [])
        for index, track in enumerate(tracks):
            track_id = track.get("id", f"idx_{index}")
            duration_string = format_duration(track.get("duration", 0))
            self.track_tree.insert(
                "", tk.END, iid=track_id, values=(track.get("title", ""), track.get("artist", ""), duration_string)
            )

    def on_track_select(self, event):
        selected = self.track_tree.selection()
        if not selected:
            return
        track_id = selected[0]

        station_id = self.cb_playlist_station.get()
        _, _, target = self.get_playlist_doc_and_target(station_id)
        tracks = target.get("tracks", [])
        for index, track in enumerate(tracks):
            if track.get("id", f"idx_{index}") == track_id:
                self.editing_track_id = track_id
                self.t_vars["url_l"].set(track.get("playback_url", ""))
                self.t_vars["url_r"].set(track.get("playback_url_r", ""))
                self.t_vars["title"].set(track.get("title", ""))
                self.t_vars["artist"].set(track.get("artist", ""))
                self.t_vars["dur"].set(format_duration(track.get("duration", 0)))
                self.t_vars["source"].set(track.get("source_url", ""))
                self.t_vars["art"].set(track.get("art_url", ""))
                self.t_vars["source_file"].set("")
                break

    def build_track_payload(self, duration: int) -> dict:
        track = {
            "title": self.t_vars["title"].get().strip(),
            "artist": self.t_vars["artist"].get().strip(),
            "duration": duration,
        }

        left_url = normalize_github_url(self.t_vars["url_l"].get().strip())
        right_url = normalize_github_url(self.t_vars["url_r"].get().strip())
        if left_url:
            track["playback_url"] = left_url
        if right_url:
            track["playback_url_r"] = right_url

        source_url = self.t_vars["source"].get().strip()
        art_url = self.t_vars["art"].get().strip()
        if source_url:
            track["source_url"] = source_url
        if art_url:
            track["art_url"] = art_url
        return track

    def convert_and_fill_current_track(self):
        if not self.ensure_ffmpeg_tools():
            return

        source_file = self.t_vars["source_file"].get().strip()
        if not source_file:
            messagebox.showerror("Error", "Pick a local source file first.")
            return

        source_path = Path(source_file)
        if not source_path.exists():
            messagebox.showerror("Error", f"Source file does not exist:\n{source_path}")
            return

        try:
            self.persist_processing_defaults_from_form()
            self.append_log(f"Converting '{source_path.name}' to stereo DFPWM...")
            left_temp, right_temp, temp_dir = self.convert_source_to_temp_pair(source_path)
            try:
                left_url, right_url = self.publish_generated_pair(left_temp, right_temp, source_path)
            finally:
                temp_dir.cleanup()

            self.t_vars["url_l"].set(left_url)
            self.t_vars["url_r"].set(right_url)
            self.auto_fill_track(self.t_vars)
            self.append_log(f"Generated stereo pair for '{source_path.name}'.")
        except subprocess.CalledProcessError as exc:
            stderr = (exc.stderr or "").strip() or str(exc)
            self.append_log(f"Conversion failed for '{source_path.name}': {stderr}")
            messagebox.showerror("Conversion Failed", stderr)
        except Exception as exc:
            self.append_log(f"Conversion/publish failed for '{source_path.name}': {exc}")
            messagebox.showerror("Conversion Failed", str(exc))

    def batch_convert_folder(self):
        if not self.ensure_ffmpeg_tools():
            return

        target = self.t_vars["publish_target"].get().strip() or "Local"
        if target != "Local":
            messagebox.showerror("Batch Conversion", "Batch conversion is local-only in this version.")
            return

        source_folder = filedialog.askdirectory(title="Select Folder to Batch Convert")
        if not source_folder:
            return

        source_root = Path(source_folder)
        output_subfolder = (self.t_vars["output_subfolder"].get().strip() or "audio").strip("/\\")
        output_root = self.root_dir / output_subfolder
        output_root.mkdir(parents=True, exist_ok=True)
        processing = self.get_processing_options()
        self.persist_processing_defaults_from_form()

        files = sorted(path for path in source_root.rglob("*") if path.is_file() and path.suffix.lower() != ".dfpwm")
        if not files:
            self.append_log("Batch conversion skipped: no files found.")
            messagebox.showinfo("Batch Conversion", "No files were found in the selected folder.")
            return

        converted = 0
        skipped = 0
        for path in files:
            relative_parent = path.parent.relative_to(source_root)
            target_dir = output_root / relative_parent
            left_output = target_dir / f"{path.stem}_L.dfpwm"
            right_output = target_dir / f"{path.stem}_R.dfpwm"
            try:
                if not self.can_probe_audio(path):
                    skipped += 1
                    self.append_log(f"Skipped non-audio file: {path.relative_to(source_root)}")
                    continue
                self.convert_media_to_pair(path, left_output, right_output, processing)
                converted += 1
                self.append_log(f"Batch converted: {path.relative_to(source_root)}")
            except subprocess.CalledProcessError as exc:
                skipped += 1
                stderr = (exc.stderr or "").strip() or str(exc)
                self.append_log(f"Failed to convert {path.relative_to(source_root)}: {stderr}")
            except Exception as exc:
                skipped += 1
                self.append_log(f"Failed to convert {path.relative_to(source_root)}: {exc}")

        summary = f"Batch conversion finished. Converted {converted}, skipped {skipped}."
        self.append_log(summary)
        messagebox.showinfo("Batch Conversion", summary)

    def add_track_to_playlist(self):
        station_id = self.cb_playlist_station.get()
        if not station_id:
            messagebox.showerror("Error", "Select a station first.")
            return

        try:
            duration = parse_duration(self.t_vars["dur"].get())
        except ValueError:
            messagebox.showerror("Error", "Duration must be MM:SS (e.g. 3:45) or a number in seconds.")
            return

        path, doc, target = self.get_playlist_doc_and_target(station_id)
        tracks = target.setdefault("tracks", [])
        highest = 0
        for track in tracks:
            track_id = str(track.get("id", ""))
            if track_id.startswith("track_"):
                try:
                    highest = max(highest, int(track_id.split("_", 1)[1]))
                except ValueError:
                    pass

        track = {"id": f"track_{highest + 1:02d}"}
        track.update(self.build_track_payload(duration))
        tracks.append(track)
        target["version"] = bump_version(target.get("version", "0"))
        save_json(path, doc)

        self.load_playlist_tracks()
        messagebox.showinfo("Success", "New track added and version bumped!")

    def update_track(self):
        if not self.editing_track_id:
            messagebox.showerror("Error", "No track selected. Click a track in the list to edit it.")
            return

        station_id = self.cb_playlist_station.get()
        try:
            duration = parse_duration(self.t_vars["dur"].get())
        except ValueError:
            messagebox.showerror("Error", "Duration must be MM:SS (e.g. 3:45) or a number in seconds.")
            return

        path, doc, target = self.get_playlist_doc_and_target(station_id)
        tracks = target.setdefault("tracks", [])
        for index, track in enumerate(tracks):
            if track.get("id", f"idx_{index}") == self.editing_track_id:
                updated = {"id": track.get("id", self.editing_track_id)}
                updated.update(self.build_track_payload(duration))
                track.clear()
                track.update(updated)
                break

        target["version"] = bump_version(target.get("version", "0"))
        save_json(path, doc)
        self.load_playlist_tracks()
        messagebox.showinfo("Success", "Track updated successfully!")

    def delete_track(self):
        selected = self.track_tree.selection()
        if not selected:
            messagebox.showerror("Error", "Please select a track to delete.")
            return

        if not messagebox.askyesno(
            "Confirm Delete", "Are you sure you want to completely remove this track from the playlist?"
        ):
            return

        track_id = selected[0]
        station_id = self.cb_playlist_station.get()
        path, doc, target = self.get_playlist_doc_and_target(station_id)
        tracks = target.get("tracks", [])
        target["tracks"] = [
            track for index, track in enumerate(tracks) if track.get("id", f"idx_{index}") != track_id
        ]
        target["version"] = bump_version(target.get("version", "0"))
        save_json(path, doc)
        self.load_playlist_tracks()

    # --- SUBMISSION LOGIC ---

    def add_track_to_submission(self):
        try:
            duration = parse_duration(self.sub_t_vars["dur"].get())
        except ValueError:
            messagebox.showerror("Error", "Duration must be MM:SS (e.g. 3:45) or a number in seconds.")
            return

        track = {
            "id": f"track_{len(self.sub_tracks) + 1:02d}",
            "title": self.sub_t_vars["title"].get().strip(),
            "artist": self.sub_t_vars["artist"].get().strip(),
            "duration": duration,
        }
        if self.sub_t_vars["source"].get().strip():
            track["source_url"] = self.sub_t_vars["source"].get().strip()
        if self.sub_t_vars["url"].get().strip():
            track["playback_url"] = normalize_github_url(self.sub_t_vars["url"].get().strip())
        if self.sub_t_vars["art"].get().strip():
            track["art_url"] = self.sub_t_vars["art"].get().strip()

        self.sub_tracks.append(track)
        self.sub_tree.insert("", tk.END, values=(track["title"], format_duration(duration)))
        for key in ("url", "title", "artist", "dur", "source", "art"):
            self.sub_t_vars[key].set("")

    def export_submission(self):
        station_id = self.sub_s_vars["id"].get().strip()
        if not station_id or not self.sub_tracks:
            messagebox.showerror("Error", "Station ID and at least 1 track are required.")
            return

        path = filedialog.asksaveasfilename(
            defaultextension=".json",
            initialfile=f"{station_id}_submission.json",
            title="Save Submission JSON",
        )
        if not path:
            return

        submission = {
            "submission_type": "rednet_radio_playlist",
            "submitted_at_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "station": {
                "station_id": station_id,
                "name": self.sub_s_vars["name"].get().strip(),
                "description": self.sub_s_vars["desc"].get().strip(),
            },
            "playlist": {
                "name": f"{self.sub_s_vars['name'].get().strip()} Playlist",
                "version": "1",
                "tracks": self.sub_tracks,
            },
        }
        save_json(Path(path), submission)
        messagebox.showinfo("Success", f"Submission saved to:\n{path}")


if __name__ == "__main__":
    app = RednetRadioStudio()
    app.mainloop()