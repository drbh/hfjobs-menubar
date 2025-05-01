<div align="center">
  <img src="https://github.com/user-attachments/assets/707fdc47-c6e4-4d62-8ede-8e4e4b20609e" width="200" height="200" alt="hfjobs-menubar logo">
  <p align="center">
      <a href="https://github.com/drbh/hfjobs-menubar/actions/workflows/build-and-release.yml"><img alt="Build and Release" src="https://img.shields.io/github/actions/workflow/status/drbh/hfjobs-menubar/build-and-release.yml?label=CI%20Release"></a>
      <a href="https://github.com/drbh/hfjobs-menubar/tags"><img alt="GitHub tag" src="https://img.shields.io/github/v/tag/drbh/hfjobs-menubar"></a>
  </p>
  <h1>hf jobs menubar app</h1>
</div>
<br/>

A small macOS menubar app to watch the status of your Hugging Face jobs.


## Quick start (on M series Mac)

```bash
curl \
  -sOL https://github.com/drbh/hfjobs-menubar/releases/download/v0.0.3/HFJobs.zip && \
  unzip HFJobs.zip && \
  open -a $(pwd)/HFJobs.app
```

## Installation (build it yourself)

### Setup Environment Variables

Copy the example environment file and update with your values:

```bash
cp .env.example .env
# Edit .env with your signing and notarization details
```

### Build

```bash
source .env  # Load environment variables
make
```

### Run

```bash
open HFJobs.app
```

## Run a job

```bash
export HF_TOKEN=hf_
uvx hfjobs run ubuntu sleep 20
```

# Screenshots

See the status of jobs (view is filtered in this case)  

<img width="664" alt="running" src="https://github.com/user-attachments/assets/d1142b80-4a7e-4e8e-ad2f-7784c2532372" />

Change or toggle the update interval  

<img width="666" alt="intervals" src="https://github.com/user-attachments/assets/03cb83e5-ed56-4ead-9942-a129c1ba3fdf" />

Get notifcations when jobs change (also toggable)  

<img width="648" alt="notifcations" src="https://github.com/user-attachments/assets/ce3f3e18-f292-40eb-bbd6-4ac33636e87a" />

Filter listed jobs by type or timeframe  

<img width="675" alt="filterview" src="https://github.com/user-attachments/assets/225e2cff-8f71-4075-8096-f1fdb98f1ecf" />




