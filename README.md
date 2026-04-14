# FALCON: Folding Abstract Layers into Coherent Org Narratives
FALCON is a structural bridge between your creative intent and the latent space of Large Language Models. Built specifically for the [Doom Emacs](https://github.com/doomemacs/doomemacs) ecosystem, it transforms [Org-mode](https://orgmode.org/) buffers into highly customizable AI chat environments within the comfort of a program fine-tuned for *wordcraft* over *decades*.

Whether you're engaging in a multi-turn technical architectural debate or just chatting it up, FALCON manages the context, the prompts and the streaming delivery within your favorite text editor.

Additionally, if writing *prose* and not *chats* is your thing, FALCON has you covered there as well by supporting plain text completion. This is configured in a similar way to the chat mode and supports the same set of samplers.

No complex library dependency chain needed, just Doom Emacs, curl and FALCON. Oh! And an OpenAI-compatable API like [openrouter](https://openrouter.ai/), [llama-swap](https://github.com/mostlygeek/llama-swap) or [llama-cpp's own server](https://github.com/ggml-org/llama.cpp) ... and a key for it.


## Installation (Doom Emacs) 
1) **Prerequisites**: Ensure `curl` is installed on your system and accessible to the 
   process running Emacs. Behind the scenes, `curl` is used to communicate to the API.
   All other dependencies should be installed already in Doom Emacs. 
2) **Register the Package**: Add the following to your `~/.doom.d/packages.el`:
   `(package! falcon :recipe (:host github :repo "invisiblebydaylight/falcon"))`
3) **Sync**: Run `doom sync` from your terminal.
4) **Configure**: Move to the **Quick Start** section to set up your first AI provider and task.
  
### Local development
If you're planning on hacking the source to this project, you may wish to just keep the
repository elsewhere and just symlink it instead:
* Clone the repository to your preferred location and then symlink it into the `~/.doom.d` directory.
* Add a reference to the project in `~/doom.d/packages.el` like below:
   `(package! falcon :recipe (:local-repo "falcon"))`
  
### API keys
If you don't want to specify an API key inside `config.el`, you can set an environment
variable called `FALCON_API_KEY` and it should use that instead.


## Quick Start: Your First Conversation
First, add a minimalist configuration to your `~/.doom.d/config.el`:

``` emacs-lisp
(map! :leader
      :desc "Falcon Chat" "G t" (lambda () (interactive) (falcon/generate-with-task 'chat)))

(use-package! falcon
  :config
  (setq falcon-completion-provider
        (make-falcon-provider
         :model "google/gemma-4-31b-it"
         :url "https://openrouter.ai/api/v1"
         :key "sk-...your-openrouter-key-here..."))

  (falcon-task-create-and-register
   'chat
   "You are a helpful assistant."
   #'falcon/falcon-chat-system-message-fn
   #'falcon/falcon-chat-message-stack-fn
   '((temperature . 1.0)
     (top-p . 0.95)
     (top-k . 64))
   :chat))
```

After saving, restart Emacs or run `M-x doom/reload`.

Now create a new Org buffer (`SPC b N` followed by `M-x org-mode`) and add the following:

```
You are Jack, a helpful assistant with expertise in software development.

* John
Hello! Can you help me understand how to structure my Emacs configuration?

* Jack

```

Place your cursor at the end of the "Jack" heading content area and press `SPC G t`, FALCON will generate a response under the heading.

The text before the first heading is your **system prompt** - it sets the AI's behavior and provides any constant content you want to be available for the whole conversation. Each top-level heading represents a **participant** in the conversation.

This quick start covers the basic usage of the 'chat' feature, but there's more to FALCON than just basic chatting. A more full-featured sample configuration is also included further on in the `Example Setup Configuration` section.


## Core Concepts
### Tasks
At the core of FALCON are the tasks a user sets up. In the `Quick Start` section above, a task named `chat` gets created by calling `falcon-task-create-and-register`. Tasks bundle up a possible default system message string as well allowing for customization on how FALCON can obtain the 'system message' and 'chat messages' from the active buffer. Finally, a task also bundles in some default sampler settings.

FALCON ships with default implementations that do the core work a user would expect, but this can be customized further. For example the `Example Setup Configuration` below sets up a `writing` task that is used on basic buffers for text continuation and then `chat` and `meta` tasks that work on Org mode buffers.

The final parameter when calling `falcon-task-create-and-register` controls which API gets called. Tasks with `:chat` end up calling `/chat/completions` of the API (appended to the URL provided in the provider). Tasks with `:completion` call the basic `/completions` API which is meant to be used with 'pretrained' models and not 'finetuned' or 'instruct' models. Besides calling different endpoints, the response structures change as well, but FALCON handles that behind the scenes.

### Providers
In order to have *something* to call out to, a 'provider' has to be created with `make-falcon-provider` and then set to `falcon-completion-provider`. The `Example Setup Configuration` has a function that wraps this behavior up behind an interactive list of the creator's favorite models, but this can obviously be customized.

Fundamentally, the 'provider' just ties together an API URL stem, an API key and a model-id to use for the request.

### Sizes and Limits
FALCON provides three variables to control token budgets:

#### Generation Limits

- `falcon-completion-word-limit`: Maximum words to generate. Set to `nil` for no limit.
- `falcon-completion-token-limit`: Maximum tokens to generate. Overrides word limit if both are set.

#### Context Limit

- `falcon-context-token-limit`: Maximum estimated tokens for the prompt (system message + conversation history). Older messages are trimmed when exceeded. Default: 8192.

#### The Math

Your model's context window must accommodate: `context-token-limit + generation-limit`. If you set context to 32K and request 4K tokens of output, your model needs at least a 36K context window.

#### Token Estimation

FALCON estimates tokens using `falcon-token-estimation-ratio` (default: 4.0 characters per token). Lower this for code-heavy buffers; raise it for prose with significant whitespace.

### Task Behaviors

Each task type serves a distinct workflow. Understanding when to use which is the key to getting value from FALCON.

#### Writing Tasks

The `:completion` API style. Designed for **base models** (not instruct-tuned). 

- Takes everything before the cursor as context
- Continues the text in the same style and voice
- Best for prose, creative writing, or code continuation
- Works in any buffer type - FALCON simply pulls all the text before the cursor as the context

**Use when:** You're drafting a novel, continuing a blog post, or working with a local base model like LLaMA.

**Note:** The system message for a task does not get used and sent to the AI.

**Note:** Most OpenRouter models are instruct-tuned and perform poorly with this API style. If you see garbled output or the model "talking to itself," switch to a chat task. This is best used in conjunction with a locally hosted 'base' model such as [gemma-3-27b-pt](https://huggingface.co/google/gemma-3-27b-pt).

#### Chat Tasks

The `:chat` API style. Designed for **instruct-tuned models**. This is the default for most users.

- Text before the first heading = system prompt
- Each top-level heading = a participant in the conversation
- Cursor position determines who responds next

**Use when:** You want a back-and-forth dialogue, technical discussion, or collaborative problem-solving.

**Note:** The participant's name gets used to prefix the top-level heading's content when building the chat messages for the AI. For example, in the Quick Start section, the chat 'turn' for 'John' would look like this: `John: Hello! Can you help me understand how to structure my Emacs configuration?`.

File can be attached to the chat context by setting a special property on the Org mode buffer. For example:

```org
#+FALCON_FILES: src/main.el src/utils.el
```

Or via a properties drawer:

```org
:PROPERTIES:
:FALCON_FILES: src/main.el src/utils.el
:END:
```

File paths are relative to the buffer's directory. Contents are injected under an `=== ATTACHED FILES ===` header in the system prompt. Useful for sharing source code, reference material, or any context too large to paste directly.

#### Meta Tasks (Falcon Blocks)

Scoped work inside `#+BEGIN_FALCON` blocks. The block content becomes the AI's context, separate from the surrounding document. An example of such a block is this:

```
#+BEGIN_FALCON :task meta
USER>> Summarize the key themes in the chapter above.
AI>>
#+END_FALCON
```

- The cursor should be placed inside the meta task to complete
- This feature only works in Org mode buffers
- The `USER`/`AI` use in the example is just an easy cue to the AI that a summary was requested, but it basically just gets handed the whole block and is told to 'complete' it.

**Use when:** You want to query or transform content without polluting the main conversation history.

### Modifiers

Modifiers let you temporarily override task parameters mid-session without editing your config. They're useful when you want the AI to shift behavior—more creative, more rigorous, shorter responses—without creating a permanent task variant.

```elisp
(falcon-task-add-modifier
 (falcon-get-task 'chat)
 'rigorous
 :temperature 0.3
 :message "Be technically precise. Ask clarifying questions if uncertain.")
```

Modifiers stack and persist for the session. Clear them with `M-x falcon/clear-all-modifiers`.


## Example Setup Configuration
The `~/.doom.d/config.el` configuration file can be modified to support configuring
`falcon` in the way that works for you. The example configuration below includes
the definition of `falcon-switch-model` that takes the a handy list of user
favorite model IDs. It also sets up keybindings for frequently accessed features as
well as basic tasks to cover the modalities of AI text generation supported by the library.

```
(map! :leader
      :desc "GenAI: Writing" "G w" (lambda () (interactive) (falcon/generate-with-task 'writing))
      :desc "GenAI: Chat" "G t" (lambda () (interactive) (falcon/generate-with-task 'chat))
      :desc "GenAI: Falcon Block Meta" "G b" (lambda () (interactive) (falcon/generate-with-task 'meta))
      :desc "Set Word Limit" "G c" #'falcon/set-word-limit
      :desc "Set Context Limit" "G C" #'falcon/set-context-token-limit
      :desc "Set AI Model ID" "G m" #'falcon/switch-model
      :desc "Set Sampling Parameter" "G p" #'falcon/set-task-parameter
      :desc "View Sampling Parameters" "G P" #'falcon/view-task-parameters
      :desc "Cancel Text Generation" "G x" #'falcon/cancel-text-generation)

;; Note: mind this rule: (model context size) >= (word/token limit) + (context token limit)
(setq falcon-context-token-limit 32768)

(use-package! falcon
  :config

  (defun falcon/switch-model ()
    "Interactively switch to a different model."
    (interactive)
    (let ((model-name (completing-read "Switch to model: " (mapcar #'car falcon-models))))
      (falcon/set-provider model-name)))

  (defvar falcon-models
    '(("gemma-4" . "google/gemma-4-31b-it")
      ("gemini-3.1-pro" . "google/gemini-3.1-pro-preview")
      ("gemini-3-flash" . "google/gemini-3-flash-preview")
      ("glm-5.1" . "z-ai/glm-5.1")
      ("glm-5" . "z-ai/glm-5")
      ("deepseek-v3.2" . "deepseek/deepseek-v3.2")
      ("kimi-k2.5" . "moonshotai/kimi-k2.5")
      ("mimo-v2-pro" . "xiaomi/mimo-v2-pro")
      ("minimax-m2.7" . "minimax/minimax-m2.7")
      ("nemotron3-super" . "nvidia/nemotron-3-super-120b-a12b")
      ("olmo3-32b" . "allenali/olmo-3-32b-instruct")
      ("olmo3-32b-think" . "allenai/olmo-3.1-32b-think")
      ("qwen-235b" . "qwen/qwen3-235b-a22b-2507")
      ("qwen3.5-122b" . "qwen/qwen3.5-122b-a10b")
      ("qwen3.5-35b" . "qwen/qwen3.5-35b-a3b")
      ("qwen3.5-27b" . "qwen/qwen3.5-27b")
      ("qwen3-coder-next" . "qwen/qwen3-coder-next")
      ("gpt-5.4" . "openai/gpt-5.4")
      ("gpt-5.4-nano" . "openai/gpt-5.4-nano")
      ("opus-4.6" . "anthropic/claude-opus-4.6")
      ("sonnet-4.6" . "anthropic/claude-sonnet-4.6"))
    "Favorite models for OpenRouter.")

  (defun falcon/set-provider (model-id)
    "Set falcon-completion-provider to use MODEL-ID."
    (interactive
     (list (completing-read "Model: " (mapcar #'car falcon-models))))
    (let ((actual-model-id (or (cdr (assoc model-id falcon-models)) model-id)))
      (setq falcon-completion-provider
            (make-falcon-provider
             :model actual-model-id
             :url "https://openrouter.ai/api/v1"
             :api-key "sk-or-v1-..."))
      (message "Falcon provider set to model: %s" actual-model-id)))

  (falcon/set-provider "gemma-4")

  (falcon-task-create-and-register
   'writing
   ""
   nil
   nil
   '((temperature . 1.0)
     (reasoning . none))
   :completion)

  (falcon-task-create-and-register
   'meta
   "You are a creative writing consultant. Analyze the provided text for consistency in character, plot, and tone. Generate targeted ideas and answer specific questions to help refine the direction of the narrative. The text provided after these instructions serves as reference material for our conversation. In our dialogue, we will discuss and analyze this reference text, but our conversation itself is separate narrative content."
   #'falcon/falcon-block-system-message-fn #'falcon/falcon-block-message-stack-fn
   '((temperature . 0.7)
     (reasoning . low))
   :chat)

  (falcon-task-create-and-register
   'chat
   "You are a helpful assistant."
   #'falcon/falcon-chat-system-message-fn
   #'falcon/falcon-chat-message-stack-fn
   '((temperature . 0.7)
     (reasoning . medium))
   :chat)

  (defun falcon/mod-rigorous ()
    "Switch to a more precise, technically rigorous mode."
    (interactive)
    (falcon-task-add-modifier
     (falcon-get-task 'chat)
     'rigorous
     :temperature 0.3
     :message "Be technically precise. If you're uncertain about any aspect of your answer, ask clarifying questions before committing to a response. Prefer accuracy over completeness."))
```

## Interactive Commands from the Example Configuration

| Binding | Command | Purpose |
|---------|---------|---------|
| `SPC G w` | `falcon/generate-with-task 'writing` | Generate text continuation |
| `SPC G t` | `falcon/generate-with-task 'chat` | Generate chat response |
| `SPC G b` | `falcon/generate-with-task 'meta` | Generate within Falcon block |
| `SPC G c` | `falcon/set-word-limit` | Set max words to generate |
| `SPC G C` | `falcon/set-context-token-limit` | Set context window size |
| `SPC G m` | `falcon/switch-model` | Switch AI model |
| `SPC G p` | `falcon/set-task-parameter` | Set sampler parameter |
| `SPC G P` | `falcon/view-task-parameters` | View active parameters |
| `SPC G x` | `falcon/cancel-text-generation` | Kill running generation |


## Unit tests
To run the unit tests, open the `run-tests.el` file, `eval` the buffer (`SPC m e b`) and then execute all the tests:

```
M-x (falcon--run-all-tests)
```


## Troubleshooting

### AI responses seem missing, cut off or context appears truncated
* Call `falcon/set-word-limit` to increase the rather low default setting
* Try lowering `falcon-token-estimation-ratio` to 2.5-3.0 for code
* Try raising to 4.5-5.0 for dense technical writing
* Consider that your actual token count may be higher than estimated

### The response gets inserted at random spots
* While waiting for the response from the AI, leave the cursor where it's at.
  This will hopefully get resolved in a future bug fix.


## Implementation Notes
* using a reasoning model when the word count is low will cause the completion
  to finish before outputting any text, making it look like it did nothing. 
* if you want to know what Openrouter's default parameters are, reference this:
  https://openrouter.ai/docs/api/reference/parameters


## Random Notes and Inspirations
* https://www.tomheon.com/2019/04/10/how-an-uber-geeky-text-mode-in-a-40-year-old-editor-saved-my-novel/
  I like the way this blog article was written and it got me thinking about how I could organize Org mode documents further.


## License

MIT
