# hf jobs menubar app

A small macOS menubar app to watch the status of your Hugging Face jobs.

## Quick start (on M series Mac)

```bash
curl \
  -sOL https://github.com/drbh/hfjobs-menubar/releases/download/v0.0.1/HFJobs.zip && \
  unzip HFJobs.zip && \
  open -a HFJobs.app
```

## Installation (build it yourself)

```bash
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
