# vllm_monitor
A bash script that monitors via SSH/tmux the Avg. Generation Tokens and the % Acceptance Rate for speculative models.

<img width="518" height="420" alt="vLLM_Monitor" src="https://github.com/user-attachments/assets/ce5e9a8f-899b-454c-beca-bcbe365aa4a7" />

# Pre-Reqs & Assumptions:
- It assumes you're running this over ssh to a remote server (can be localhost, though)
- You must have tmux installed as you'll want to launch your vllm session interactively inside the tmux
- - This is just for the sake to better handle the connection to the host and the log. While I'm also polling logs from (i.e.:) docker logs -f vllm-node, several launcher recipes behave differently and you might find youself with a non interactive terminal or one that sends the logs to limbo. Simply using tmux is versatile and works almost always (see instructions).
- SSHPASS is used with -e to pass your ssh password. Please set this variable *before* launching this script (export SSHPASS=xxxx)
- I'm assuming You know I vibe-coded the crap out of this and I will provide no warranty :)

# Dependencies
- jq (client-side only)
- tmux (DGX side)
- sshpass (Client-side only)

# What it does:
It monitors the output logs from vllm and looks for two parameters:
  - Avg. Draft Acceptance Rate
  - Avg. Generation Throughput

Then once it have a few (min 5) it starts averaging and plotting those values and color-code the bars.

In my case, I'm running Qwen3.5-122B-A10B Hybrid model (see https://forums.developer.nvidia.com/t/qwen3-5-122b-a10b-on-single-spark-up-to-51-tok-s-v2-1-patches-quick-start-benchmark) and I was trying to know for real what actual throughput I was getting with MTP Speculative Decoding trying values like none: 1, 2 and 3. So Having that my Draft acceptance rate is in Green or sometimes dipping into the yellows, It's actually acceptable as it means that the extra effort generating those tokens are converted to a net-win.

But there are scenarios where MTP=1 was actually giving me better performance (Less tok/sec, but 90+% of acceptance rate) rendering in a net-performance gain. I will make it more versatile in the next version so more people can use it for your particular use cases (sOOn).

# Instructions
- I'm assuming you installed jq and tmux (sudo apt install tmux jq) in you DGX Spark or GB10 box.
- Create a new tmux session and name it vllm (important!)
- Launch your vllm as your normally do, validate that you CAN see logs on your tmux screen
- Detach from tmux (optional)

Exmple: 
- - 'tmux new -s vllm'
  - 'run-recipe.sh qwen3.5-122b-a10b-fp8'
  - Ctrl+B, then "D" to detach.
  - To go back to the session (if needed), just 'tmux attach -t vllm'

Now that vllm is running, just launch vllm_monitor.sh on your local or remote computer with ssh access to the host:
*'./monitor_vllm_v4.sh -t yourUserName@dgx.host.local'*

 
