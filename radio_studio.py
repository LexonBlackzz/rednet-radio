#!/usr/bin/env python3
import json
import os
import sys
from urllib.parse import urlparse, unquote
from datetime import datetime, timezone
from pathlib import Path
import tkinter as tk
from tkinter import ttk, filedialog, messagebox

DEFAULT_PUBLIC_BASE = "https://raw.githubusercontent.com/LexonBlackzz/rednet-radio/main"

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
    if not url: return url
    parsed = urlparse(url)
    if parsed.netloc not in {"github.com", "www.github.com"}: return url
    parts = [part for part in parsed.path.split("/") if part]
    if len(parts) < 5 or parts[2] != "blob": return url
    owner, repo, _blob, branch = parts[:4]
    rest = "/".join(parts[4:])
    return f"https://raw.githubusercontent.com/{owner}/{repo}/{branch}/{rest}"

def bump_version(value) -> str:
    try:
        return str(int(str(value)) + 1)
    except (TypeError, ValueError):
        return datetime.now(timezone.utc).strftime("%Y%m%d%H%M%S")

def parse_duration(val: str) -> int:
    """Converts MM:SS, HH:MM:SS, or raw seconds into total seconds."""
    val = val.strip()
    if not val:
        raise ValueError("Empty duration")
    if ":" in val:
        parts = val.split(":")
        if len(parts) == 2:
            m, s = parts
            return int(m) * 60 + int(s)
        elif len(parts) == 3:
            h, m, s = parts
            return int(h) * 3600 + int(m) * 60 + int(s)
        else:
            raise ValueError("Invalid time format")
    else:
        return int(val)

def format_duration(seconds: int) -> str:
    """Converts raw seconds back into MM:SS format for the UI."""
    try:
        sec = int(seconds)
        m = sec // 60
        s = sec % 60
        if m >= 60:
            h = m // 60
            m = m % 60
            return f"{h}:{m:02d}:{s:02d}"
        return f"{m}:{s:02d}"
    except (ValueError, TypeError):
        return str(seconds)

class RednetRadioStudio(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title("Rednet Radio Studio")
        self.geometry("900x650")
        
        self.root_dir = Path.cwd()
        self.stations_file = None
        self.playlists_dir = None
        self.editing_track_id = None
        
        # UI Setup
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
        
        self.s_vars = {
            "id": tk.StringVar(), "name": tk.StringVar(), "desc": tk.StringVar(),
            "channel": tk.StringVar(), "host": tk.StringVar(), "base": tk.StringVar(value=DEFAULT_PUBLIC_BASE)
        }
        
        fields = [
            ("Station ID (e.g. vaporwave):", "id"),
            ("Station Name:", "name"),
            ("Description:", "desc"),
            ("Rednet Channel (Optional):", "channel"),
            ("Host Label (Optional):", "host"),
            ("Public Base URL:", "base"),
        ]
        for i, (label, key) in enumerate(fields):
            ttk.Label(form_frame, text=label).grid(row=i, column=0, sticky=tk.W, padx=10, pady=5)
            ttk.Entry(form_frame, textvariable=self.s_vars[key], width=40).grid(row=i, column=1, sticky=tk.EW, padx=10, pady=5)
            
        ttk.Button(form_frame, text="Create Station", command=self.create_station).grid(row=len(fields), column=1, pady=20, sticky=tk.E, padx=10)

    def build_playlist_tab(self):
        top_frame = ttk.Frame(self.tab_playlist)
        top_frame.pack(fill=tk.X, pady=5)
        ttk.Label(top_frame, text="Select Station:").pack(side=tk.LEFT, padx=5)
        self.cb_playlist_station = ttk.Combobox(top_frame, state="readonly", width=40)
        self.cb_playlist_station.pack(side=tk.LEFT, padx=5)
        self.cb_playlist_station.bind("<<ComboboxSelected>>", self.load_playlist_tracks)

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
        self.track_tree.column("dur", width=60, stretch=False)
        self.track_tree.pack(fill=tk.BOTH, expand=True, padx=5, pady=5)
        self.track_tree.bind("<<TreeviewSelect>>", self.on_track_select)

        btn_frame = ttk.Frame(left_container)
        btn_frame.pack(fill=tk.X, pady=5)
        ttk.Button(btn_frame, text="Delete Selected Track", command=self.delete_track).pack(side=tk.RIGHT, padx=5)

        form_frame = ttk.LabelFrame(content, text="Track Details")
        content.add(form_frame, weight=2)

        self.t_vars = {
            "url": tk.StringVar(), "title": tk.StringVar(), "artist": tk.StringVar(),
            "dur": tk.StringVar(), "source": tk.StringVar(), "art": tk.StringVar()
        }

        ttk.Label(form_frame, text="Playback URL (.dfpwm):").grid(row=0, column=0, sticky=tk.W, padx=10, pady=5)
        url_frame = ttk.Frame(form_frame)
        url_frame.grid(row=0, column=1, sticky=tk.EW, padx=10, pady=5)
        ttk.Entry(url_frame, textvariable=self.t_vars["url"]).pack(side=tk.LEFT, fill=tk.X, expand=True)
        ttk.Button(url_frame, text="✨ Auto-Fill Metadata", command=lambda: self.auto_fill_track(self.t_vars)).pack(side=tk.RIGHT, padx=(5, 0))

        fields = [
            ("Title:", "title"), ("Artist:", "artist"),
            ("Duration (MM:SS or Secs):", "dur"), ("Original Source URL (Opt):", "source"),
            ("Cover Art URL (Opt):", "art")
        ]
        for i, (label, key) in enumerate(fields, start=1):
            ttk.Label(form_frame, text=label).grid(row=i, column=0, sticky=tk.W, padx=10, pady=5)
            ttk.Entry(form_frame, textvariable=self.t_vars[key], width=40).grid(row=i, column=1, sticky=tk.EW, padx=10, pady=5)

        action_frame = ttk.Frame(form_frame)
        action_frame.grid(row=len(fields)+1, column=0, columnspan=2, pady=20, sticky=tk.E, padx=10)
        
        ttk.Button(action_frame, text="Clear Form", command=self.clear_form).pack(side=tk.LEFT, padx=5)
        ttk.Button(action_frame, text="Update Selected Track", command=self.update_track).pack(side=tk.LEFT, padx=5)
        ttk.Button(action_frame, text="Add as New Track", command=self.add_track_to_playlist).pack(side=tk.LEFT, padx=5)

    def build_submit_tab(self):
        content = ttk.PanedWindow(self.tab_submit, orient=tk.HORIZONTAL)
        content.pack(fill=tk.BOTH, expand=True)
        
        self.sub_tracks = []

        left = ttk.Frame(content)
        content.add(left, weight=1)
        
        s_frame = ttk.LabelFrame(left, text="1. Station Info")
        s_frame.pack(fill=tk.X, padx=5, pady=5)
        self.sub_s_vars = {"id": tk.StringVar(), "name": tk.StringVar(), "desc": tk.StringVar()}
        ttk.Label(s_frame, text="Station ID:").grid(row=0, column=0, sticky=tk.W, padx=5, pady=2)
        ttk.Entry(s_frame, textvariable=self.sub_s_vars["id"]).grid(row=0, column=1, sticky=tk.EW, padx=5, pady=2)
        ttk.Label(s_frame, text="Station Name:").grid(row=1, column=0, sticky=tk.W, padx=5, pady=2)
        ttk.Entry(s_frame, textvariable=self.sub_s_vars["name"]).grid(row=1, column=1, sticky=tk.EW, padx=5, pady=2)
        ttk.Label(s_frame, text="Description:").grid(row=2, column=0, sticky=tk.W, padx=5, pady=2)
        ttk.Entry(s_frame, textvariable=self.sub_s_vars["desc"]).grid(row=2, column=1, sticky=tk.EW, padx=5, pady=2)

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
        
        self.sub_t_vars = {
            "url": tk.StringVar(), "title": tk.StringVar(), "artist": tk.StringVar(),
            "dur": tk.StringVar(), "source": tk.StringVar(), "art": tk.StringVar()
        }
        
        url_frame = ttk.Frame(right)
        url_frame.grid(row=0, column=0, columnspan=2, sticky=tk.EW, padx=10, pady=5)
        ttk.Label(url_frame, text="Playback URL:").pack(side=tk.LEFT)
        ttk.Entry(url_frame, textvariable=self.sub_t_vars["url"]).pack(side=tk.LEFT, fill=tk.X, expand=True, padx=5)
        ttk.Button(url_frame, text="✨ Auto-Fill", command=lambda: self.auto_fill_track(self.sub_t_vars)).pack(side=tk.RIGHT)

        fields = [("Title:", "title"), ("Artist:", "artist"), ("Duration (MM:SS):", "dur"), ("Source URL:", "source"), ("Art URL:", "art")]
        for i, (label, key) in enumerate(fields, start=1):
            ttk.Label(right, text=label).grid(row=i, column=0, sticky=tk.W, padx=10, pady=5)
            ttk.Entry(right, textvariable=self.sub_t_vars[key], width=40).grid(row=i, column=1, sticky=tk.EW, padx=10, pady=5)

        ttk.Button(right, text="Add Track", command=self.add_track_to_submission).grid(row=len(fields)+1, column=1, pady=20, sticky=tk.E, padx=10)

    # --- LOGIC ---

    def get_playlist_path(self, sid: str) -> Path:
        doc = load_json(self.stations_file)
        for s in doc.get("stations", []):
            if s.get("station_id") == sid:
                url = s.get("playlist_url", "")
                if url:
                    filename = unquote(urlparse(url).path.split("/")[-1])
                    if filename:
                        if not filename.endswith(".json"): filename += ".json"
                        return self.playlists_dir / filename
        return self.playlists_dir / f"{sid}.json"

    def auto_fill_track(self, var_dict):
        url = normalize_github_url(var_dict["url"].get().strip())
        if not url:
            messagebox.showwarning("Warning", "Please enter a URL first!")
            return
        
        var_dict["url"].set(url)

        filename = unquote(url.split("/")[-1])
        if filename.endswith(".dfpwm"): filename = filename[:-6]
        
        if " - " in filename:
            artist, title = filename.split(" - ", 1)
            if not var_dict["artist"].get(): var_dict["artist"].set(artist.strip())
            if not var_dict["title"].get(): var_dict["title"].set(title.strip())
        elif not var_dict["title"].get():
            var_dict["title"].set(filename.replace("_", " ").strip())

    def browse_workspace(self):
        folder = filedialog.askdirectory(title="Select Rednet Radio Root or Site Folder")
        if folder:
            self.load_workspace(Path(folder))

    def load_workspace(self, path: Path):
        self.root_dir = path
        self.stations_file = path / "stations.json"
        self.playlists_dir = path / "playlists"
        self.lbl_workspace.config(text=str(path))
        
        if not self.stations_file.exists():
            if messagebox.askyesno("Workspace Initialization", f"No stations.json found in:\n{path}\n\nWould you like to initialize this folder as a Workspace?"):
                save_json(self.stations_file, {"stations": []})
                self.playlists_dir.mkdir(exist_ok=True)
            else:
                self.station_tree.delete(*self.station_tree.get_children())
                return
                
        self.refresh_station_list()

    def refresh_station_list(self):
        self.station_tree.delete(*self.station_tree.get_children())
        doc = load_json(self.stations_file)
        stations = doc.get("stations", [])
        
        cb_values = []
        for s in stations:
            sid = s.get("station_id", "unknown")
            name = s.get("name", "Unnamed")
            self.station_tree.insert("", tk.END, values=(f"{name} ({sid})",))
            cb_values.append(sid)
            
        self.cb_playlist_station["values"] = cb_values
        
        if cb_values and not self.cb_playlist_station.get():
            self.cb_playlist_station.current(0)
            self.load_playlist_tracks()

    def create_station(self):
        if not self.stations_file or not self.stations_file.exists():
            messagebox.showerror("Error", "Workspace not initialized.")
            return
            
        sid = self.s_vars["id"].get().strip()
        name = self.s_vars["name"].get().strip()
        
        if not sid or not name:
            messagebox.showerror("Error", "Station ID and Name are required.")
            return

        doc = load_json(self.stations_file)
        stations = doc.setdefault("stations", [])
        
        if any(s.get("station_id") == sid for s in stations):
            messagebox.showerror("Error", "Station ID already exists!")
            return
            
        base = self.s_vars["base"].get().strip().rstrip("/")
        station = {
            "station_id": sid,
            "name": name,
            "description": self.s_vars["desc"].get().strip(),
            "playlist_url": f"{base}/playlists/{sid}.json",
            "rednet_channel": self.s_vars["channel"].get().strip() or f"rednet_radio_v1:station:{sid}",
            "host_label": self.s_vars["host"].get().strip()
        }
        
        stations.append(station)
        save_json(self.stations_file, doc)
        
        playlist_doc = {"name": f"{name} Playlist", "version": "1", "tracks": []}
        save_json(self.playlists_dir / f"{sid}.json", playlist_doc)
        
        messagebox.showinfo("Success", f"Station '{name}' created successfully!")
        self.refresh_station_list()
        for var in self.s_vars.values(): var.set("")
        self.s_vars["base"].set(DEFAULT_PUBLIC_BASE)

    def on_tab_change(self, event):
        if self.notebook.index("current") == 1: 
            self.refresh_station_list() 

    # --- TRACK EDITOR LOGIC ---

    def clear_form(self):
        self.editing_track_id = None
        for k in ["url", "title", "artist", "dur", "source", "art"]: 
            self.t_vars[k].set("")
        for item in self.track_tree.selection():
            self.track_tree.selection_remove(item)

    def load_playlist_tracks(self, event=None):
        self.clear_form()
        self.track_tree.delete(*self.track_tree.get_children())
        sid = self.cb_playlist_station.get()
        if not sid: return
        
        path = self.get_playlist_path(sid)
        doc = load_json(path)
        
        if isinstance(doc, list): tracks = doc
        elif "playlist" in doc and isinstance(doc["playlist"], dict): tracks = doc["playlist"].get("tracks", [])
        else: tracks = doc.get("tracks", [])

        for idx, t in enumerate(tracks):
            tid = t.get("id", f"idx_{idx}")
            dur_str = format_duration(t.get("duration", 0))
            self.track_tree.insert("", tk.END, iid=tid, values=(t.get("title", ""), t.get("artist", ""), dur_str))

    def on_track_select(self, event):
        selected = self.track_tree.selection()
        if not selected: return
        tid = selected[0]
        
        sid = self.cb_playlist_station.get()
        path = self.get_playlist_path(sid)
        doc = load_json(path)
        
        if isinstance(doc, list): tracks = doc
        elif "playlist" in doc and isinstance(doc["playlist"], dict): tracks = doc["playlist"].get("tracks", [])
        else: tracks = doc.get("tracks", [])

        for idx, t in enumerate(tracks):
            if t.get("id", f"idx_{idx}") == tid:
                self.editing_track_id = tid
                self.t_vars["url"].set(t.get("playback_url", ""))
                self.t_vars["title"].set(t.get("title", ""))
                self.t_vars["artist"].set(t.get("artist", ""))
                self.t_vars["dur"].set(format_duration(t.get("duration", 0)))
                self.t_vars["source"].set(t.get("source_url", ""))
                self.t_vars["art"].set(t.get("art_url", ""))
                break

    def add_track_to_playlist(self):
        sid = self.cb_playlist_station.get()
        if not sid: return messagebox.showerror("Error", "Select a station first.")
            
        try: dur = parse_duration(self.t_vars["dur"].get())
        except ValueError: return messagebox.showerror("Error", "Duration must be MM:SS (e.g., 3:45) or a number in seconds.")

        path = self.get_playlist_path(sid)
        doc = load_json(path)
        
        if isinstance(doc, list):
            doc = {"name": f"{sid} Playlist", "version": "1", "tracks": doc}
            target = doc
        elif "playlist" in doc and isinstance(doc["playlist"], dict): target = doc["playlist"]
        else: target = doc
            
        tracks = target.setdefault("tracks", [])
        highest = 0
        for t in tracks:
            tid = str(t.get("id", ""))
            if tid.startswith("track_"):
                try: highest = max(highest, int(tid.split("_", 1)[1]))
                except ValueError: pass
        
        track = {
            "id": f"track_{highest + 1:02d}",
            "title": self.t_vars["title"].get().strip(),
            "artist": self.t_vars["artist"].get().strip(),
            "duration": dur
        }
        if self.t_vars["source"].get().strip(): track["source_url"] = self.t_vars["source"].get().strip()
        if self.t_vars["url"].get().strip(): track["playback_url"] = normalize_github_url(self.t_vars["url"].get().strip())
        if self.t_vars["art"].get().strip(): track["art_url"] = self.t_vars["art"].get().strip()
        
        tracks.append(track)
        target["version"] = bump_version(target.get("version", "0"))
        save_json(path, doc)
        
        self.load_playlist_tracks()
        messagebox.showinfo("Success", "New track added and version bumped!")

    def update_track(self):
        if not self.editing_track_id:
            return messagebox.showerror("Error", "No track selected. Click a track in the list to edit it.")
            
        sid = self.cb_playlist_station.get()
        try: dur = parse_duration(self.t_vars["dur"].get())
        except ValueError: return messagebox.showerror("Error", "Duration must be MM:SS (e.g., 3:45) or a number in seconds.")

        path = self.get_playlist_path(sid)
        doc = load_json(path)
        
        if isinstance(doc, list): target = {"name": f"{sid} Playlist", "version": "1", "tracks": doc}; doc = target
        elif "playlist" in doc and isinstance(doc["playlist"], dict): target = doc["playlist"]
        else: target = doc
            
        tracks = target.setdefault("tracks", [])
        for idx, t in enumerate(tracks):
            if t.get("id", f"idx_{idx}") == self.editing_track_id:
                t["title"] = self.t_vars["title"].get().strip()
                t["artist"] = self.t_vars["artist"].get().strip()
                t["duration"] = dur
                
                url = self.t_vars["url"].get().strip()
                if url: t["playback_url"] = normalize_github_url(url)
                elif "playback_url" in t: del t["playback_url"]
                
                src = self.t_vars["source"].get().strip()
                if src: t["source_url"] = src
                elif "source_url" in t: del t["source_url"]
                
                art = self.t_vars["art"].get().strip()
                if art: t["art_url"] = art
                elif "art_url" in t: del t["art_url"]
                break
                
        target["version"] = bump_version(target.get("version", "0"))
        save_json(path, doc)
        
        self.load_playlist_tracks()
        messagebox.showinfo("Success", "Track updated successfully!")

    def delete_track(self):
        selected = self.track_tree.selection()
        if not selected:
            return messagebox.showerror("Error", "Please select a track to delete.")
            
        tid = selected[0]
        if not messagebox.askyesno("Confirm Delete", "Are you sure you want to completely remove this track from the playlist?"):
            return
            
        sid = self.cb_playlist_station.get()
        path = self.get_playlist_path(sid)
        doc = load_json(path)
        
        if isinstance(doc, list): target = {"name": f"{sid} Playlist", "version": "1", "tracks": doc}; doc = target
        elif "playlist" in doc and isinstance(doc["playlist"], dict): target = doc["playlist"]
        else: target = doc
            
        tracks = target.get("tracks", [])
        target["tracks"] = [t for idx, t in enumerate(tracks) if t.get("id", f"idx_{idx}") != tid]
        target["version"] = bump_version(target.get("version", "0"))
        
        save_json(path, doc)
        self.load_playlist_tracks()

    # --- SUBMISSION LOGIC ---

    def add_track_to_submission(self):
        try: dur = parse_duration(self.sub_t_vars["dur"].get())
        except ValueError: return messagebox.showerror("Error", "Duration must be MM:SS (e.g., 3:45) or a number in seconds.")
            
        track = {
            "id": f"track_{len(self.sub_tracks) + 1:02d}",
            "title": self.sub_t_vars["title"].get().strip(),
            "artist": self.sub_t_vars["artist"].get().strip(),
            "duration": dur
        }
        if self.sub_t_vars["source"].get().strip(): track["source_url"] = self.sub_t_vars["source"].get().strip()
        if self.sub_t_vars["url"].get().strip(): track["playback_url"] = normalize_github_url(self.sub_t_vars["url"].get().strip())
        if self.sub_t_vars["art"].get().strip(): track["art_url"] = self.sub_t_vars["art"].get().strip()
        
        self.sub_tracks.append(track)
        self.sub_tree.insert("", tk.END, values=(track["title"], format_duration(dur)))
        for k in ["url", "title", "artist", "dur", "source", "art"]: self.sub_t_vars[k].set("")

    def export_submission(self):
        sid = self.sub_s_vars["id"].get().strip()
        if not sid or not self.sub_tracks: return messagebox.showerror("Error", "Station ID and at least 1 track are required.")
            
        path = filedialog.asksaveasfilename(defaultextension=".json", initialfile=f"{sid}_submission.json", title="Save Submission JSON")
        if not path: return
        
        submission = {
            "submission_type": "rednet_radio_playlist",
            "submitted_at_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "station": {"station_id": sid, "name": self.sub_s_vars["name"].get().strip(), "description": self.sub_s_vars["desc"].get().strip()},
            "playlist": {"name": f"{self.sub_s_vars['name'].get().strip()} Playlist", "version": "1", "tracks": self.sub_tracks},
        }
        
        save_json(Path(path), submission)
        messagebox.showinfo("Success", f"Submission saved to:\n{path}")

if __name__ == "__main__":
    app = RednetRadioStudio()
    app.mainloop()