;;; run-tests.el --- Interactive test runner for falcon

;; Load dependencies
(require 'falcon)
(require 'ert)

;; Load test definitions
(load-file "falcon-test.el")

(defun falcon--run-all-tests ()
  "Run all falcon test functions interactively."
  (interactive)
  (ert-run-tests-interactively "test-falcon-.*"))

(defun falcon--run-single-test (test-name)
  "Run a single falcon test by TEST-NAME."
  (interactive "Test name: ")
  (ert-run-tests-interactively (concat "falcon-" test-name)))

;; These tests hasn't been automated yet, but can be useful
;; to smoketest the text completion interfce.
(defun test-falcon-openrouter ()
  "Testing the stuff out."
  (let ((provider falcon-completion-provider)
        (prompt-args (list :system "You are a helpful assistant."
                           :messages "This is a test "))
        (accumulated ""))
    (falcon--openrouter-completion
     provider
     prompt-args
     (lambda (delta-text)
       (setq accumulated (concat accumulated delta-text)))
     (lambda (final-text)
       (message "Final result: %s" final-text))
     (lambda (error-type error-data)
       (message "Error: %s - %s" error-type error-data)))))
(defun test-falcon-openrouter-blocking ()
  "Testing the stuff out."
  (let ((provider falcon-completion-provider)
        (prompt-args (list :system "You are a helpful assistant."
                           :messages "This is a test ")))
    (falcon--openrouter-completion
     provider
     prompt-args)))

;; Provide for require
(provide 'run-tests)

;;; run-tests.el ends here
