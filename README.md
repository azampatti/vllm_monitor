# vllm_monitor
A simple script that monitors via SSH/tmux the Avg. Generation Tokens and the % Acceptance Rate for speculative models.

#Pre-Reqs & Assumptions:
- It assumes you're running this over ssh to a remote server (can be localhost, though)
- You must have tmux installed as you'll want to launch your vllm session interactively inside the tmux
- - This is just for the sake to better handle the connection to the host and the lcg. I can (and I'm doing it for some models as well) extrack a 'docker logs -f vllm-node' but people build them with different names or launch them with launchers with -d and there are too many scenarios to cover, just install tmux, create a new session named 'vllm' (tmux new -s vllm) and launch your vllm there
- SSHPASS is used with -e to pass your ssh password. Please set this variable before launching this script (export SSHPASS=xxxx)
- I'm assuming You know I vibe-coded this and I will provide no warranty :)

#What it does:
It monitors the output logs from vllm and looks for two parameters:
  - Avg. Draft Acceptance Rate
  - Avg. Generation Throughput
Then once it have a few (min 5) it starts averaging and plotting those values and color-code the bars.

In my case, I'm running Qwen3.5-122B-A10B Hybrid model (see https://forums.developer.nvidia.com/t/qwen3-5-122b-a10b-on-single-spark-up-to-51-tok-s-v2-1-patches-quick-start-benchmark) and I was trying to know for real what actual throughput I was getting with MTP Speculative Decoding trying values like none: 1, 2 and 3. So HAving that my Draft acceptance rate is in Green or sometimes dipping into the yellows, It's actually acceptable as it means that the extra effort generating those tokens are converted to a net-win.

Bt there are scenarios where MTP=1 was actually giving me better performance (Less tok/sec, but 90+% of acceptance rate) rendering in a net-performance gain.

I will make it more versatile in the next version so more people can use it for your particular use cases (sOOn).

