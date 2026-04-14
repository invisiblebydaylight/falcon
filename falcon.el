;;; falcon.el --- An AI writing assistant for Emacs utilizing the `llm` library.   -*- lexical-binding: t; -*-
;;;
;;; Commentary:
;;;
;;; Falcon is a suite of tools for Emacs, designed for writers who want to
;;; leverage generative AI for text prediction and assistance directly within
;;; their writing buffer. It is tailored for a seamless writing workflow,
;;; offering context-aware generation, customizable AI tasks, and a modular
;;; system for adjusting AI behavior on the fly.

(require 'cl-lib)
(require 'org)
(require 'ox-md)
(require 'json)

(defcustom falcon-completion-provider nil
  "LLM provider for completion requests.
Use make-falcon-provider to create this object."
  :type '(choice (const :tag "None" nil)
          (sexp :tag "Provider object"))
  :group 'falcon)

(defcustom falcon-completion-word-limit nil
  "Maximum number of words to generate in AI completions.
Set to nil for no limit."
  :type '(choice (integer :tag "Word count")
          (const :tag "No limit" nil))
  :local t
  :group 'falcon)

(defcustom falcon-completion-token-limit nil
  "Maximum number of tokens to generate in AI completions.
Set to nil for no token-based limit. Overrides word-limit if both are set."
  :type '(choice (integer :tag "Token count")
          (const :tag "No token limit" nil))
  :local t
  :group 'falcon)

(defcustom falcon-context-token-limit nil
  "Maximum number of estimated tokens to use in generating the prompt for AI."
  :type '(choice (integer :tag "Context Token count")
          (const :tag "No context token limit" nil))
  :local t
  :group 'falcon)

(defcustom falcon-token-estimation-ratio 4.0
  "Characters per token for estimation in falcon--estimate-tokens.
Higher values are more conservative (estimate fewer tokens).
Set lower for code, higher for prose with lots of whitespace."
  :type 'float
  :group 'falcon)

;;;###autoload
(defun falcon/set-word-limit (limit)
  "Set word LIMIT for current buffer."
  (interactive "nWord limit (0 for no limit): ")
  (setq-local falcon-completion-word-limit (if (> limit 0) limit nil))
  (message "Word limit set to %s" (or limit "no limit")))

;;;###autoload
(defun falcon/set-token-limit (limit)
  "Set token LIMIT for current buffer.
LIMIT is a positive integer for the hard token limit in the response."
  (interactive "nToken limit (0 for no limit): ")
  (setq-local falcon-completion-token-limit (if (> limit 0) limit nil))
  (message "Token limit set to %s" (or limit "no limit")))

;;;###autoload
(defun falcon/set-context-token-limit (limit)
  "Set token LIMIT for context in current buffer.
This affects how many tokens are used for context in chat tasks."
  (interactive "nContext token limit: ")
  (setq-local falcon-context-token-limit (if (> limit 0) limit nil))
  (message "Context token limit set to %s" (or limit "no limit")))

(defgroup falcon nil
  "Falcon's AI writing tools configuration."
  :group 'tools)


(defvar falcon-task-registry (make-hash-table :test 'equal))

(defvar-local falcon--current-curl-process nil
  "The currently active curl process for text generation, if any.")

(defun falcon--mode-line-indicator ()
  "Return falcon emoji when generation is active."
  " 🦅")

(define-minor-mode falcon-mode
  "Minor mode for Falcon AI writing assistance."
  :global t
  (if falcon-mode
      (add-to-list 'global-mode-string '(:eval (falcon--mode-line-indicator)))
    (setq global-mode-string
          (delete '(:eval (falcon--mode-line-indicator)) global-mode-string))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Interactives

(defun falcon--get-buffer-content ()
  "Copy the buffer content, start to point, into kill ring and return it."
  (let ((content (buffer-substring-no-properties (point-min) (point))))
    content))

(defun falcon--get-current-org-chapter-content ()
  "Return content of current Org top-level heading, excluding all blocks.
The content is determined from the chapter start up to the point of invocation.
If the point is inside a special block (e.g., FALCON), the content
ends right before that block begins."
  (save-excursion
    (let ((original-point (point)))
      (condition-case nil
          (progn
            ;; find the top-level heading for the current section
            (org-back-to-heading t)
            (while (> (org-current-level) 1)
              (outline-up-heading 1 t))
            (let* ((start (point))
                   (end original-point)
                   element)
              ;; determine the correct endpoint for the context.
              ;; If we are inside a special block, the context should end
              ;; *before* that block. Otherwise, it ends at the cursor.
              (save-excursion
                (goto-char original-point)
                (setq element (org-element-context))
                (while (and element (not (eq (org-element-type element) 'special-block)))
                  (setq element (org-element-property :parent element)))
                (when (and element (eq (org-element-type element) 'special-block))
                  ;; We are in a block. Set the end point to the block's start.
                  (setq end (org-element-property :begin element))))

              ;; now grab the text, clean it, and export it
              (when (< start end)
                (let* ((raw-text (buffer-substring-no-properties start end))
                       (cleaned-text (falcon--remove-org-blocks raw-text)))
                  (when (and cleaned-text (> (length cleaned-text) 0))
                    (with-temp-buffer
                      (insert cleaned-text)
                      (let ((org-export-with-smart-quotes nil)
                            (org-export-with-author nil)
                            (org-export-with-section-numbers nil)
                            (org-export-with-toc nil)
                            (org-export-with-tags nil)
                            (org-export-with-properties nil)
                            (org-export-with-drawers nil))
                        (org-export-as 'ascii nil nil nil))))))))
        (error nil)))))

;; NOTE: tried a few different approaches to make sure that the special blocks don't
;; get exported, but really the only thing that seems to work well is something
;; manual like this. would love to switch to something less hacky...
(defun falcon--remove-org-blocks (text)
  "Remove all #+BEGIN...#+END blocks from TEXT string."
  (let ((case-fold-search t)) ; Make regex search case-insensitive for BEGIN/END
    (with-temp-buffer
      (insert text)
      (goto-char (point-min))
      (while (re-search-forward "^[ \t]*#\\+BEGIN_" nil t)
        (let ((start (match-beginning 0)))
          (when (re-search-forward "^[ \t]*#\\+END_" nil t)
            ;; delete from the start of #+BEGIN_ line to the end of #+END_ line
            (delete-region start (line-end-position))
            ;; restart search from the beginning after a deletion
            (goto-char (point-min)))))
      (buffer-string))))

(defun falcon--get-context-content ()
  "Get content based on context: region > Org chapter > buffer to point.
Returns a string suitable for AI prompting."
  (cond
   ((use-region-p)
    (buffer-substring-no-properties (region-beginning) (region-end)))
   ((derived-mode-p 'org-mode)
    (or (falcon--get-current-org-chapter-content) ; Use org content if available
        (falcon--get-buffer-content)))            ; Fall back to buffer content
   (t
    (falcon--get-buffer-content))))

(defun falcon--streaming-insert-handler (initial-point)
  "Return a streaming handler function for inserting text at INITIAL-POINT.
The handler receives a string chunk and inserts it at the tracking point."
  (let ((insertion-point initial-point))
    (lambda (chunk)
      (when (and chunk (stringp chunk) (> (length chunk) 0))
        (save-excursion
          (goto-char insertion-point)
          (insert chunk))
        (setq insertion-point (+ insertion-point (length chunk)))))))

(defun falcon--build-prompt-args (task)
  "Build prompt arguments plist from TASK configuration."
  (let* ((active-params (falcon-task-get-active-parameters task))
         (system-message-fn (or (falcon-task-system-message-fn task)
                                #'falcon/default-system-message-fn))
         (message-stack-fn (or (falcon-task-message-stack-fn task)
                               #'falcon/default-message-stack-fn))
         (system-message (funcall system-message-fn task (falcon-task-modifiers task)))
         (prompt-message-stack (funcall message-stack-fn task)))
    (list :system system-message
          :messages prompt-message-stack
          :max-tokens (or (alist-get 'max-tokens active-params)
                          (falcon--calculate-max-tokens))
          :temperature (alist-get 'temperature active-params)
          :top-p (alist-get 'top-p active-params)
          :top-k (alist-get 'top-k active-params)
          :frequency-penalty (alist-get 'frequency-penalty active-params)
          :presence-penalty (alist-get 'presence-penalty active-params)
          :repetition-penalty (alist-get 'repetition-penalty active-params)
          :min-p (alist-get 'min-p active-params)
          :top-a (alist-get 'top-a active-params)
          :seed (alist-get 'seed active-params)
          :reasoning (alist-get 'reasoning active-params)
          :verbosity (alist-get 'verbosity active-params)
          :response-format (alist-get 'response-format active-params))))


(defun falcon--generate-completion-with-task (task)
  "Generate AI completion using TASK's custom message functions."
  (unless (and (boundp 'falcon-completion-provider)
               falcon-completion-provider)
    (error "No completion provider configured. Set 'falcon-completion-provider'"))

  (let* ((prompt-args (falcon--build-prompt-args task))
         (provider falcon-completion-provider)
         (insertion-point (point))
         (stream-handler (falcon--streaming-insert-handler insertion-point)))
    (message "Generating AI response with task '%s' using model '%s'..."
             (falcon-task-name task)
             (falcon-provider-model provider))
    (falcon--openrouter-completion
     provider
     prompt-args
     task
     stream-handler
     (lambda (final-text)
       (message "Text prediction finished (%d words)."
                (length (split-string final-text "\\s-+" t))))
     (lambda (error-type error-data)
       (message "Error: %s - %s" error-type error-data)))))

;;;###autoload
(defun falcon/generate-with-task (task-name)
  "Generate completion using specified TASK-NAME."
  (interactive
   (list (completing-read "Task: " (hash-table-keys falcon-task-registry))))
  (let ((task (falcon-get-task task-name)))
    (unless task
      (error "No task named '%s'" task-name))
    (falcon--generate-completion-with-task task)))

;;;###autoload
(defun falcon/generate-in-falcon-block ()
  "Generate completion specifically for FALCON blocks."
  (interactive)
  (unless (falcon--in-falcon-block-p)
    (error "Not inside a FALCON block"))
  (let* ((params (falcon--get-falcon-block-parameters))
         (task-name (or (cdr (assoc :task params)) 'writing))
         (task (falcon-get-task task-name)))
    (unless task
      (error "No task named '%s'" task-name))
    (falcon--generate-completion-with-task task)))

(defun falcon--calculate-max-tokens ()
  "Calculate max tokens from user's preferred limit.
Prioritizes token-limit over word-limit."
  (cond
   (falcon-completion-token-limit falcon-completion-token-limit)
   (falcon-completion-word-limit (ceiling (* falcon-completion-word-limit 1.3)))
   (t nil)))  ; No limit

(defun falcon--files-from-buffer-property ()
  "Get FALCON_FILES from the buffer, supporting both drawer and keyword styles.
It first attempts to read a space-separated FALCON_FILES property from a
:PROPERTIES: drawer. If that fails, it reads the value from a
#+FALCON_FILES keyword line."
  (or
   ;; Method 1: Try the :PROPERTIES: drawer first.
   ;; This function is smart and returns a list directly.
   (org-entry-get-multivalued-property (point-min) "FALCON_FILES")

   ;; Method 2: If the above returns nil, try the #+FALCON_FILES keyword method.
   (when-let* ((keywords (org-collect-keywords '("FALCON_FILES")))
               (value-string (cadr (assoc "FALCON_FILES" keywords))))

     ;; `org-collect-keywords` gives a string, so we must split it.
     (split-string value-string))))

(defun falcon--concatenate-file-contents (file-list)
  "Concatenate contents of files in FILE-LIST into a single string.
Returns a string with each file's content separated by a delimiter.
If a file cannot be read, it includes an error message in the result.
File paths are interpreted relative to the current buffer's directory."
  (if (null file-list)
      ""
    (let ((result "")
          (delimiter "\n\n=== FILE: %s ===\n\n"))
      (dolist (file-path file-list)
        (let ((full-path (expand-file-name file-path (file-name-directory (buffer-file-name)))))
          (if (file-readable-p full-path)
              (let ((file-content (with-temp-buffer
                                    (insert-file-contents full-path)
                                    (buffer-string))))
                (setq result (concat result (format delimiter file-path) file-content "\n\n")))
            (setq result (concat result (format delimiter file-path)
                                 (format "!!! ERROR: Could not read file: %s !!!\n\n" full-path))))))
      result)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Task and Modifier configuration

(cl-defstruct (falcon-task (:constructor falcon-task-create))
  "AI task with customizable message construction."
  name
  system-message ;default system message to use when system-message-fn is not set
  system-message-fn ; function to build the system message
  message-stack-fn ; function to build the user/assistant message stack OR just the user message text
  modifiers ; list of (name . alist) modifier pairs
  parameters ;base parameters alist
  api-style) ; should be :chat or :completion

(defconst falcon--supported-parameters
  '(max-tokens temperature top-p top-k frequency-penalty presence-penalty
    repetition-penalty min-p top-a seed reasoning verbosity response-format)
  "Canonical list of OpenRouter parameters we support.")

(defun falcon--format-param-value (value)
  "Format VALUE for display, handling nil/t/symbols transparently."
  (cond
   ((null value) "nil")
   ((eq value t) "t")
   ((symbolp value) (symbol-name value))
   ((floatp value) (format "%.3f" value))
   ((numberp value) (number-to-string value))
   (t (format "%S" value))))

;;;###autoload
(defun falcon/set-task-parameter (task-name param-name value)
  "Set base PARAM-NAME to VALUE for TASK-NAME.
Modifies the task's permanent parameters, not temporary modifiers."
  (interactive
   (let* ((task-name (intern (completing-read "Task: " (hash-table-keys falcon-task-registry))))
          (task (falcon-get-task task-name))
          (current-params (falcon-task-parameters task))
          (param-name-str (completing-read
                           "Parameter: "
                           (mapcar #'symbol-name falcon--supported-parameters)))
          (param-name (intern param-name-str))
          (current-value (alist-get param-name current-params))
          (value-str (read-string (format "Value for %s (current: %s, empty to unset): "
                                          param-name-str
                                          (falcon--format-param-value current-value))))
          (value (cond
                  ((string= value-str "") nil)
                  ((string= value-str "nil") nil)
                  ((string= value-str "t") t)
                  ((string-match-p "\\`[0-9]+\\'" value-str) (string-to-number value-str))
                  ((string-match-p "\\`[0-9]*\\.[0-9]+\\'" value-str) (string-to-number value-str))
                  ;; Reasoning levels and other symbols
                  ((string-match-p "\\`[a-zA-Z][a-zA-Z0-9-]*\\'" value-str) (intern value-str))
                  (t value-str))))
     (list task-name param-name value)))
  
  (let ((task (falcon-get-task task-name)))
    (unless task
      (error "No task named '%s'" task-name))
    
    (unless (memq param-name falcon--supported-parameters)
      (warn "Unknown parameter '%s'" param-name))
    
    (setf (alist-get param-name (falcon-task-parameters task) nil nil 'eq) value)
    
    (message "Set %s parameter '%s' to %s"
             task-name
             param-name
             (falcon--format-param-value value))))

;;;###autoload
(defun falcon/view-task-parameters (task-name)
  "Display all parameters for TASK-NAME in a helpful buffer."
  (interactive (list (completing-read "Task: " (hash-table-keys falcon-task-registry))))
  (let* ((task-sym (intern task-name))
         (task (falcon-get-task task-sym))
         (provider-model (falcon-provider-model falcon-completion-provider))
         (params (falcon-task-parameters task)))
    (with-output-to-temp-buffer "*Falcon Task Parameters*"
      (princ (format "Parameters for '%s' (model ID: %s):\n\n" task-name provider-model))
      (if params
          (dolist (param falcon--supported-parameters)
            (let ((value (alist-get param params)))
              (princ (format "%-20s %s\n" (symbol-name param)
                             (falcon--format-param-value value)))))
        (princ "No parameters set.")))))

(defun falcon/set-task-parameters (task-name &rest parameters)
  "Set multiple PARAMETERS for the task TASK-NAME.
PARAMETERS should be alternating keywords and values.
Example: (falcon/set-task-parameters 'writing :temperature 1.0 :top-p 0.95)
This function is non-interactive and designed for use in config files."
  (let ((task (falcon-get-task (if (stringp task-name) (intern task-name) task-name))))
    (unless task
      (error "No task named '%s'" task-name))
    
    ;; Process parameters as keyword-value pairs
    (when parameters
      (let ((param-list (cl-loop for (key value) on parameters by #'cddr
                                 when (keywordp key)
                                 collect (cons (intern (substring (symbol-name key) 1)) value))))
        ;; Apply each parameter
        (dolist (param-value-pair param-list)
          (let ((param-name (car param-value-pair))
                (value (cdr param-value-pair)))
            (unless (memq param-name falcon--supported-parameters)
              (warn "falcon/set-task-parameters: Unknown parameter '%s' for task '%s'"
                    param-name
                    task-name))
            (setf (alist-get param-name (falcon-task-parameters task)) value))))
      
      (message "Set %d parameter(s) for task '%s'"
               (/ (length parameters) 2)
               (falcon-task-name task)))))

(defun falcon-task-get-active-parameters (task)
  "Get all active parameters of TASK with proper precedence.
Modifiers later in stack override earlier ones and base parameters.
This works even if parameters doesn't initially contain the param being
modified."
  (let ((result (copy-alist (falcon-task-parameters task))))
    ;; apply modifiers in order (later ones override earlier)
    (dolist (modifier-pair (falcon-task-modifiers task))
      (let ((modifier-alist (cdr modifier-pair)))
        (dolist (param modifier-alist)
          (setf (alist-get (car param) result nil nil 'equal) (cdr param)))))
    result))

(defun falcon-task-add-modifier (task name &rest parameters)
  "Add a modifier called NAME to the TASK with custom PARAMETERS.
PARAMETERS should be alternating keywords and values like :temperature 0.9.
Does nothing if no parameters are provided."
  (when (and name parameters)
    ;; Convert (&rest parameters) to alist format
    (let ((modifier-alist (cl-loop for (key value) on parameters by #'cddr
                                   when (keywordp key)
                                   collect (cons (intern (substring (symbol-name key) 1)) value))))
      (when modifier-alist
        (falcon-task-push-modifier task name modifier-alist)))))

(defun falcon-task-push-modifier (task name modifier-alist)
  "ADD a NAME modifier with MODIFIER-ALIST properties onto TASK's modifier stack.
Does nothing if MODIFIER-ALIST is nil or empty."
  (when (and name modifier-alist (not (null modifier-alist)))
    (setf (falcon-task-modifiers task)
          (append (falcon-task-modifiers task)
                  (list (cons name modifier-alist))))))

(defun falcon-task-pop-modifier (task)
  "Remove the last modifier from TASK's modifier stack.
Returns the popped modifier (name . alist) or nil if stack is empty."
  (let* ((modifiers (falcon-task-modifiers task))
         (new-modifiers (butlast modifiers))
         (popped (car (last modifiers))))
    (setf (falcon-task-modifiers task) new-modifiers)
    popped))

(defun falcon-task-remove-modifier-by-name (task name)
  "Remove all modifiers with NAME from TASK's modifier stack.
Returns list of removed modifiers."
  (let ((removed '()))
    (setf (falcon-task-modifiers task)
          (cl-remove-if (lambda (modifier-pair)
                          (when (string= (car modifier-pair) name)
                            (push modifier-pair removed)
                            t))
                        (falcon-task-modifiers task)))
    removed))

;;;###autoload
(defun falcon/clear-all-modifiers (task-name)
  "Remove all modifiers from a task named TASK-NAME."
  (interactive
   (list (completing-read "Task: " (hash-table-keys falcon-task-registry))))

  ;; Convert string to symbol if needed
  (let* ((task-sym (if (stringp task-name) (intern task-name) task-name))
         (task (falcon-get-task task-sym)))
    (unless task
      (error "No task named '%s'" task-name))
    (setf (falcon-task-modifiers task) nil)
    (message "Cleared all modifiers from '%s'" task-name)))

(defun falcon-task-create-and-register (name &optional system-message system-message-fn message-stack-fn parameters api-style)
  "Create and register a `falcon-task`' by NAME.
NAME is the task's symbol. Optionally SYSTEM-MESSAGE-FN and USER-MESSAGE-FN can
be passed and are expected return the system message and user message strings.
SYSTEM-MESSAGE is the base system message string to use and PARAMETERS is an
alist of base parameters for the task. API-STYLE is either :chat or :completion
and that determine which API endpoint is called, /v1/chat/completions
or /v1/completions respectively."
  (let ((task (falcon-task-create :name name
                                  :system-message system-message
                                  :system-message-fn system-message-fn
                                  :message-stack-fn message-stack-fn
                                  :parameters parameters
                                  :api-style api-style)))
    (puthash name task falcon-task-registry)
    task))

(defun falcon-register-task (task)
  "Register TASK in global registry."
  (puthash (falcon-task-name task) task falcon-task-registry))

(defun falcon-get-task (name)
  "Get task from registry by NAME."
  (gethash name falcon-task-registry))

(defun falcon/default-system-message-fn (task modifiers)
  "Default fn to build system message from TASK system-message with MODIFIERS."
  (let* ((base-message (falcon-task-system-message task))
         (message-modifiers (cl-remove-if-not
                             (lambda (modifier-pair)
                               (assq 'message (cdr modifier-pair)))
                             modifiers))
         (modifier-messages (mapcar (lambda (modifier-pair)
                                      (cdr (assq 'message (cdr modifier-pair))))
                                    message-modifiers)))
    (if modifier-messages
        (concat base-message "\n\n" (string-join modifier-messages "\n\n"))
      base-message)))

(defun falcon/default-message-stack-fn (_task)
  "Default function to build user message.
This is the default implementation that pulls the buffer content to point."
  (falcon--get-context-content))

(defun falcon/falcon-block-system-message-fn (task modifiers)
  "Build system message for FALCON blocks, using TASK and MODIFIERS."
  (let* ((base-message (falcon-task-system-message task))
         (message-modifiers (cl-remove-if-not
                             (lambda (modifier-pair)
                               (assq 'message (cdr modifier-pair)))
                             modifiers))
         (modifier-messages (mapcar (lambda (modifier-pair)
                                      (cdr (assq 'message (cdr modifier-pair))))
                                    message-modifiers))
         (document-context (falcon--get-current-org-chapter-content))
         (main-message (if modifier-messages
                           (concat base-message "\n\n" (string-join modifier-messages "\n\n"))
                         base-message)))
    (concat main-message
            "\n\nORIGINAL CONTENT:\n\n"
            document-context)))

(defun falcon/falcon-block-message-stack-fn (_task)
  "Build user message from within a FALCON block."
  (falcon--get-falcon-block-content))

(defun falcon/falcon-chat-system-message-fn (task modifiers)
  "Build system message for chat tasks using content before first heading.
TASK is the falcon task being executed.
MODIFIERS is the list of active modifiers."
  (let* ((base-message (falcon-task-system-message task))
         (sys-message
          ;; Get content before first heading
          (save-excursion
            (goto-char (point-min))
            (let ((content-before-first-heading
                   (if (re-search-forward org-heading-regexp nil t)
                       (string-trim (buffer-substring-no-properties (point-min) (match-beginning 0)))
                     (string-trim (buffer-substring-no-properties (point-min) (point-max))))))
              ;; Remove Org metadata lines (lines starting with #+)
              (string-join
               (cl-remove-if (lambda (line) (string-prefix-p "#+" line))
                             (split-string content-before-first-heading "\n"))
               "\n"))))
         (effective-sys-message (if (string= sys-message "") base-message sys-message))
         (message-modifiers (cl-remove-if-not
                             (lambda (modifier-pair)
                               (assq 'message (cdr modifier-pair)))
                             modifiers))
         (modifier-messages (mapcar (lambda (modifier-pair)
                                      (cdr (assq 'message (cdr modifier-pair))))
                                    message-modifiers))
         (base-result (string-trim
                       (if modifier-messages
                           (concat effective-sys-message "\n\n" (string-join modifier-messages "\n\n"))
                         effective-sys-message)))
         (file-contents (when-let ((file-list (falcon--files-from-buffer-property)))
                          (falcon--concatenate-file-contents file-list))))
    (if file-contents
        (concat base-result "\n\n=== ATTACHED FILES ===\n\n" file-contents)
      base-result)))

(defun falcon/falcon-chat-message-stack-fn (task)
  "Build chatlog string from Org headings for chat TASKs, limited by token count.
Returns a string with format =NAME: CONTENT\\n\\n= for the top-level headings
that fit into the token budget, in reverse order so headings at the bottom of
the buffer ar added first. Defaults to 8192 token limit if
=falcon-context-token-limit= is  undefined."
  (let* ((max-tokens (or falcon-context-token-limit
                         8192))         ; Default fallback
         (system-message-fn (or (falcon-task-system-message-fn task)
                                #'falcon/default-system-message-fn))
         (system-prompt-tokens (falcon--estimate-tokens
                                (funcall system-message-fn task (falcon-task-modifiers task))))
         (available-tokens (max 100 (- max-tokens system-prompt-tokens 100))) ; Reserve some buffer
         (all-messages '())
         (final-chatlog ""))

    (when (> system-prompt-tokens max-tokens)
      (warn "FALCON: System prompt token estimate (%d) exceeds token limit (%d)" system-prompt-tokens max-tokens))

    ;; collect all messages first (including empty ones)
    (org-element-map (org-element-parse-buffer) 'headline
      (lambda (headline)
        (when (= (org-element-property :level headline) 1)
          (let* ((name (org-element-property :raw-value headline))
                 (content-begin (org-element-property :contents-begin headline))
                 (content-end (org-element-property :contents-end headline))
                 (content (if (and content-begin content-end)
                              (string-trim (buffer-substring-no-properties content-begin content-end))
                            "")))
            (push (format "%s: %s" name content) all-messages))))
      nil)

    (let ((current-tokens 0)
          (messages-to-include '()))
      (dolist (message all-messages)
        (let ((message-tokens (falcon--estimate-tokens message)))
          ;; add message if it fits, otherwise stop
          (if (<= (+ current-tokens message-tokens) available-tokens)
              (progn
                (push message messages-to-include)
                (setq current-tokens (+ current-tokens message-tokens)))
            ;; if this message alone exceeds the limit, we stop
            (cl-return))))

      ;; build final chatlog string (messages are already in correct order)
      (setq final-chatlog (string-join messages-to-include "\n\n")))
    (string-trim final-chatlog)))

(defun falcon--estimate-tokens (text)
  "Estimate token count for TEXT (approximately 4 characters per token)."
  (ceiling (/ (length text) (float falcon-token-estimation-ratio))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Falcon custom Org block configuration

(defun falcon--in-falcon-block-p ()
  "Return non-nil if point is inside a FALCON block."
  (save-excursion
    (org-in-block-p '("FALCON"))))

(defun falcon--get-falcon-block-parameters ()
  "Return parameters of the enclosing FALCON block as an alist.
Returns nil if not inside a FALCON block."
  (when (falcon--in-falcon-block-p)
    (save-excursion
      ;; move to the beginning of the block
      (org-backward-element)
      (let ((element (org-element-at-point)))
        (when (and (eq (org-element-type element) 'special-block)
                   (string= (org-element-property :type element) "FALCON"))
          (let ((param-string (org-element-property :parameters element)))
            (when param-string
              (org-babel-parse-header-arguments param-string))))))))

(defun falcon--get-falcon-block-content ()
  "Return the content inside the current FALCON block.
Returns nil if not inside a FALCON block."
  (when (falcon--in-falcon-block-p)
    (save-excursion
      ;; Find the containing block
      (let ((context (org-element-context)))
        ;; Navigate up the element tree to find the special block
        (while (and context (not (and (eq (org-element-type context) 'special-block)
                                      (string= (org-element-property :type context) "FALCON"))))
          (setq context (org-element-property :parent context)))

        (when context
          (let ((contents-begin (org-element-property :contents-begin context))
                (contents-end (org-element-property :contents-end context)))
            (when (and contents-begin contents-end)
              (let ((content (buffer-substring-no-properties contents-begin contents-end)))
                (string-trim content)))))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Falcon provider implementation

(cl-defstruct falcon-provider
  (url "https://openrouter.ai/api/v1/chat/completions" :type string)
  (model "qwen/qwen3-next-80b-a3b-instruct" :type string)
  (api-key nil :type (or null string))
  (do-completion-fn #'falcon--openrouter-completion :type function))

(defun falcon--openrouter-completion (provider prompt-args task &optional stream-handler on-success on-error)
  "Send a completion request to PROVIDER with settings and text from PROMPT-ARGS.
TASK is the requesting falcon-task which is needed to determine what API
endpoint to call - normal completions or chat completions.
If STREAM-HANDLER is provided, streams the response using SSE.
STREAM-HANDLER is called with each chunk of generated text.
ON-SUCCESS is called when streaming completes (optional).
ON-ERROR is called with error info if request fails (optional)."
  (let ((model (falcon-provider-model provider))
        (api-key (falcon-provider-api-key provider))
        (url (falcon-provider-url provider))
        (api-style (falcon-task-api-style task)))
    ;; Try to pull the API key from an env var if it's not supplied
    (unless api-key
      (setq api-key (getenv "FALCON_API_KEY")))
    (unless api-key
      (error "No OpenRouter API key provided and FALCON_API_KEY environment variable not set"))

    (pcase api-style
      (:chat
       (falcon--openrouter-chat-completion
        model
        api-key
        (format "%s/chat/completions" url)
        prompt-args
        stream-handler
        on-success
        on-error))
      (:completion
       (falcon--openrouter-plain-completion
        model
        api-key
        (format "%s/completions" url)
        prompt-args
        stream-handler
        on-success
        on-error))
      (_
       (error "Falcon: unknown API style '%s'. Use :chat or :completion for this parameter" api-style)))))


(defun falcon--openrouter-chat-completion (model api-key url prompt-args &optional stream-handler on-success on-error)
  "Send a /v1/chat/completions request to URL with settings from PROMPT-ARGS.
API-KEY and MODEL are used in the request to openrouter for
security and to specify the model id to use for completion.
If STREAM-HANDLER is provided, streams the response using SSE.
STREAM-HANDLER is called with each chunk of generated text.
ON-SUCCESS is called when streaming completes (optional).
ON-ERROR is called with error info if request fails (optional)."
  ;; build the message array for the Openrouter API
  (let ((chat-messages (list))
        (system-message (plist-get prompt-args :system))
        (messages (plist-get prompt-args :messages)))
    ;; Add a system message if it exists
    (when system-message
      (push (list (cons "role" "system") (cons "content" system-message)) chat-messages))

    ;; Add user message.
    (push (list (cons "role" "user") (cons "content" messages)) chat-messages)
    
    ;; Reverse to maintain order: system first, then user
    (setq chat-messages (nreverse chat-messages))

    (let* ((request-body (list :model model :messages chat-messages))
           (request-body (if stream-handler
                             (append request-body '(:stream t))
                           request-body)))
      (if stream-handler
          (falcon--openrouter-stream-request
           url api-key request-body prompt-args
           stream-handler on-success on-error)
        (falcon--openrouter-sync-request
         url api-key request-body prompt-args)))))

(defun falcon--openrouter-plain-completion (model api-key url prompt-args &optional stream-handler on-success on-error)
  "Send a /v1/completions request to URL with settings and text from PROMPT-ARGS.
API-KEY and MODEL are used in the request to openrouter for
security and to specify the model id to use for completion.
If STREAM-HANDLER is provided, streams the response using SSE.
STREAM-HANDLER is called with each chunk of generated text.
ON-SUCCESS is called when streaming completes (optional).
ON-ERROR is called with error info if request fails (optional)."
  ;; build the message array for the Openrouter API
  (let* ((messages (plist-get prompt-args :messages))
         (request-body (list :model model :prompt messages))
         (request-body (if stream-handler
                           (append request-body '(:stream t))
                         request-body)))
    (if stream-handler
        (falcon--openrouter-stream-request
         url api-key request-body prompt-args
         stream-handler on-success on-error)
      (falcon--openrouter-sync-request
       url api-key request-body prompt-args))))

(defun falcon--build-request-body (base-body prompt-args)
  "Build the complete request body from BASE-BODY.
Sampler settings from PROMPT-ARGS."
  (let ((temperature (plist-get prompt-args :temperature))
        (top-p (plist-get prompt-args :top-p))
        (top-k (plist-get prompt-args :top-k))
        (frequency-penalty (plist-get prompt-args :frequency-penalty))
        (presence-penalty (plist-get prompt-args :presence-penalty))
        (repetition-penalty (plist-get prompt-args :repetition-penalty))
        (min-p (plist-get prompt-args :min-p))
        (top-a (plist-get prompt-args :top-a))
        (seed (plist-get prompt-args :seed))
        (max-tokens (plist-get prompt-args :max-tokens))
        (reasoning (plist-get prompt-args :reasoning))
        (verbosity (plist-get prompt-args :verbosity))
        (response-format (plist-get prompt-args :response-format))
        (result (copy-sequence base-body)))
    (when max-tokens
      (unless (eq max-tokens 0)
        (plist-put result :max_tokens max-tokens)))
    (when temperature
      (plist-put result :temperature temperature))
    (when top-p
      (plist-put result :top_p top-p))
    (when top-k
      (plist-put result :top_k top-k))
    (when frequency-penalty
      (plist-put result :frequency_penalty frequency-penalty))
    (when presence-penalty
      (plist-put result :presence_penalty presence-penalty))
    (when repetition-penalty
      (plist-put result :repetition_penalty repetition-penalty))
    (when min-p
      (plist-put result :min_p min-p))
    (when top-a
      (plist-put result :top_a top-a))
    (when seed
      (plist-put result :seed seed))
    (when verbosity
      (plist-put result :verbosity verbosity))
    (when reasoning
      (unless (eq reasoning 'none)
        (plist-put result :reasoning (list :effort (symbol-name reasoning)))))
    (when response-format
      (plist-put result :response_format response-format))
    
    ;; (let ((debug-result (copy-sequence result)))
    ;;   (plist-put debug-result :messages "[...truncated for debug...]")
    ;;   (message "DEBUG: prompt-args:\n%s\n" debug-result))

    result))

(defun falcon--openrouter-sync-request (url api-key request-body prompt-args)
  "Make synchronous completion request to URL using curl.
MODEL and API-KEY are used to generate a response based on MESSAGES.
Sampler settings are pulled from PROMPT-ARGS."
  (unless (executable-find "curl")
    (error "Curl executable not found in PATH. Please install curl"))
  
  (let* ((request-data (json-encode (falcon--build-request-body request-body prompt-args)))
         (response-buffer (generate-new-buffer " *falcon-curl-response*"))
         (result nil))
    
                                        ;(message "DEBUG: this is the request JSON:\n%s\n" request-data)
    (unwind-protect
        (progn
          (falcon-mode 1)
          ;; Execute curl synchronously
          (with-current-buffer response-buffer
            (call-process "curl" nil '(t nil) nil  ; '(t nil) = stdout to buffer, stderr to /dev/null
                          "-s"  ; silent (no progress)
                          "-S"  ; but show errors
                          "-X" "POST"
                          "-H" (format "Authorization: Bearer %s" api-key)
                          "-H" "HTTP-Referer: https://github.com/invisiblebydaylight/falcon"
                          "-H" "X-OpenRouter-Title: falcon"
                          "-H" "Content-Type: application/json"
                          "-d" request-data
                          url)
            
            ;; Parse response - it should be pure JSON now
            (goto-char (point-min))
            (let ((response-text (buffer-string)))
                                        ;(message "DEBUG: response from server:\n%s\n" response-text)
              (if (string-empty-p (string-trim response-text))
                  (error "Empty JSON response from server")
                (condition-case err
                    (let* ((response-data (json-read-from-string response-text))
                           (choices (alist-get 'choices response-data))
                           (first-choice (when (and choices (> (length choices) 0))
                                           (aref choices 0)))
                           (message (when first-choice
                                      (alist-get 'message first-choice)))
                           (generated-text (or (when message
                                                 (alist-get 'content message))
                                               (alist-get 'text first-choice))))
                      (setq result generated-text))
                  (json-error
                   (error "JSON parse error: %S. Response was: %s" err response-text)))))))
      
      ;; Cleanup
      (falcon-mode 0)
      (kill-buffer response-buffer))
    result))

(defun falcon--openrouter-stream-request (url api-key request-body prompt-args stream-handler on-success on-error)
  "Make streaming completion request to URL using SSE.
API-KEY is sent in the request headers for authentication.
Sampler settings are pulled from PROMPT-ARGS.
Calls STREAM-HANDLER with each chunk of text received.
Calls ON-SUCCESS when complete, ON-ERROR if failed.
REQUEST-BODY should be a plist in the form of:
 (:model MODEL-ID-STRING
  :messages MESSAGES-STRING
  :stream t)"
  (unless (executable-find "curl")
    (error "Curl executable not found in PATH. Please install curl"))

  (let* ((accumulated-text "")
         (buffer-content "")
         (request-data (json-encode (falcon--build-request-body request-body prompt-args))))
                                        ;(message "DEBUG: request-data:\n%s\n====>" request-data)
    (setq falcon--current-curl-process
          (make-process
           :name "openrouter-stream"
           :buffer nil
           :command `("curl"
                      "-N"
                      "-X" "POST"
                      "-H" ,(format "Authorization: Bearer %s" api-key)
                      "-H" "HTTP-Referer: https://github.com/invisiblebydaylight/falcon"
                      "-H" "X-OpenRouter-Title: falcon"
                      "-H" "Content-Type: application/json"
                      "-H" "Accept: text/event-stream"
                      "-d" ,request-data
                      ,url)
           :filter
           (lambda (_proc output)
             (setq buffer-content (concat buffer-content output))
                                        ;(message "DEBUG: buffer-content:\n%s\n" buffer-content)
             ;; Process complete SSE events (lines starting with "data: ")
             (while (string-match "data: \\(\\(?:.\\|\n\\)*?\\)\n\n" buffer-content)
               (let* ((json-data (match-string 1 buffer-content)))
                 (setq buffer-content (substring buffer-content (match-end 0)))
                 ;; Skip [DONE] signal
                 (unless (string= json-data "[DONE]")
                   (let ((parsed-data (condition-case err
                                          (json-read-from-string json-data)
                                        (error
                                         (message "JSON parse error: %S for data: %s" err json-data)
                                         nil))))
                     (when parsed-data
                       (let* ((choices (alist-get 'choices parsed-data))
                              (first-choice (when (and choices (> (length choices) 0))
                                              (aref choices 0)))
                              (delta (when first-choice
                                       (alist-get 'delta first-choice)))
                              (text (when first-choice
                                      (alist-get 'text first-choice)))
                              (delta-text (when delta
                                            (alist-get 'content delta)))
                              (current-text (or delta-text text)))
                         (when current-text
                           (setq accumulated-text (concat accumulated-text current-text))
                           (funcall stream-handler current-text)))))))))
           :sentinel
           (lambda (_proc event)
             (cond
              ((string-match-p "finished" event)
               (when on-success
                 (funcall on-success accumulated-text)))
              ((or (string-match-p "exited abnormally" event)
                   (string-match-p "failed" event))
               (when on-error
                 (funcall on-error 'process-failed event))))
             (setq falcon--current-curl-process nil)
             (falcon-mode 0)
             (force-mode-line-update))))
    (falcon-mode 1)
    (force-mode-line-update)))

;;;###autoload
(defun falcon/cancel-text-generation ()
  "Cancels the currently running curl process, cancelling text generation."
  (interactive)
  (when (and falcon--current-curl-process
             (process-live-p falcon--current-curl-process))
    (kill-process falcon--current-curl-process)
    (message "Falcon text generation cancelled."))
  (setq falcon--current-curl-process nil)
  (falcon-mode 0))

(provide 'falcon)
;;; falcon.el ends here
