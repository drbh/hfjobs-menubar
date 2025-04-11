# hf jobs menubar app

This is a simple menubar app that shows the current Hugging Face job statuses.

## Quick start

```bash
curl -OL https://github.com/drbh/hfjobs-menubar/releases/download/v0.0.1/HFJobs.zip && unzip HFJobs.zip
open -a HFJobs.app
```

## Installation (build it yourself)

```bash
make
```

## Run

```bash
open HFJobs.app
```

## Run a job

```bash
export HF_TOKEN=hf_
uvx hfjobs run ubuntu sleep 20
```
