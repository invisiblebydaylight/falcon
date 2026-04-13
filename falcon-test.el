;;; falcon-test.el --- Tests for falcon

(require 'org)
(require 'ert)
(require 'falcon)

(ert-deftest test-falcon-get-buffer-content ()
  "Test buffer content extraction to the point."
  (with-temp-buffer
    (let ((test-content "Hello world!\nThis is line 2.\nCursor will be here -->"))
      (insert test-content)
      (goto-char 26)
      (let ((result (falcon--get-buffer-content)))
        (should (string= result "Hello world!\nThis is line"))))))

(ert-deftest test-falcon-get-current-org-chapter-content ()
  "Test Org chapter content extraction."
  (let ((test-content "* Chapter 1 :tag
This is chapter 1 content.
It has multiple lines.

** Subsection 1.1
Subsection content.

* Chapter 2 :tag2
This is chapter 2."))

    ;; Test 1: Normal Org document with headings
    (with-temp-buffer
      (erase-buffer)
      (insert test-content)
      (org-mode)

      ;; test cursor in chapter 1
      (goto-char 50)                    ; somewhere in chapter 1 heading
      (let ((result (falcon--get-current-org-chapter-content)))
        (should (string-prefix-p "Chapter 1" result))
        (should (string-match "This is chapter 1 content." result))
        (should (not (string-match "Subsection content." result))))

      ;; test cursor in chapter 2
      (goto-char (point-max))           ; end of buffer (in chapter 2)
      (let ((result (falcon--get-current-org-chapter-content)))
        (should (string-prefix-p "Chapter 2" result))
        (should (string-match "This is chapter 2." result))
        (should (not (string-match "Chapter 1" result)))))

    ;; Test 2: Org buffer without any headings (should return nil)
    (with-temp-buffer
      (insert "This is just some text\nwithout any org headings.\n")
      (org-mode)
      (goto-char (point-min))
      (let ((result (falcon--get-current-org-chapter-content)))
        (should (null result))))

    ;; Test 3: Empty Org buffer (should return nil)
    (with-temp-buffer
      (org-mode)
      (let ((result (falcon--get-current-org-chapter-content)))
        (should (null result))))

    ;; Test 4: Non-Org mode buffer (should return nil)
    (with-temp-buffer
      (insert "* This looks like a heading but isn't in org mode\n")
      (fundamental-mode)                ; or text-mode, any non-org mode
      (let ((result (falcon--get-current-org-chapter-content)))
        (should (null result))))

    ;; Test 5: Buffer with content before first heading (should return nil when point is before first heading)
    (with-temp-buffer
      (insert "Preamble text before any headings\n\n")
      (insert test-content)
      (org-mode)
      (goto-char (point-min))       ; point is in preamble, before first heading
      (let ((result (falcon--get-current-org-chapter-content)))
        (should (null result))))))

(ert-deftest test-falcon-get-context-content-fallback ()
  "Test that get-context-content falls back correctly when org chapter returns nil."

  ;; Test 1: Point at beginning of buffer (should return empty string)
  (with-temp-buffer
    (insert "Some text without org headings\n")
    (org-mode)
    (goto-char (point-min))

    (let ((result (falcon--get-context-content)))
      (should (string= result "")))) ; Empty string when point is at beginning

  ;; Test 2: Point moved into buffer content (should return content up to point)
  (with-temp-buffer
    (insert "Some text without org headings\n")
    (org-mode)
    (goto-char 15) ; Move point into the text

    (let ((result (falcon--get-context-content)))
      (should (string= result "Some text with")))) ; Content from start to point

  ;; Test 3: Verify it works with region selection (highest priority)
  (with-temp-buffer
    (insert "Some text without org headings\nAnd more text here")
    (org-mode)
    (goto-char 20) ; Set point somewhere
    (push-mark 5)   ; Set mark to create region from position 5-20
    (activate-mark)

    (let ((result (falcon--get-context-content)))
      (should (string= result " text without o"))))) ; Only the selected region

(ert-deftest test-falcon-task-basic-creation ()
  "Test basic task creation and accessors."
  (let ((task (falcon-task-create
               :name "test-task"
               :system-message "Test system message"
               :parameters '((temperature . 0.7)
                             (max-tokens . 1000))
               :modifiers '((urgent . ((temperature . 0.9)))))))
    (should (equal (falcon-task-name task) "test-task"))
    (should (equal (falcon-task-system-message task) "Test system message"))
    (should (equal (falcon-task-parameters task)
                   '((temperature . 0.7) (max-tokens . 1000))))
    (should (equal (falcon-task-modifiers task)
                   '((urgent . ((temperature . 0.9))))))))

(ert-deftest test-falcon-task-get-active-parameters-no-modifiers ()
  "Test active parameters with only base parameters."
  (let ((task (falcon-task-create
               :name "no-mods"
               :parameters '((temperature . 0.7) (style . "concise")))))
    (let ((active-params (falcon-task-get-active-parameters task)))
      (should (equal (alist-get 'temperature active-params) 0.7))
      (should (equal (alist-get 'style active-params) "concise")))))

(ert-deftest test-falcon-task-modifier-precedence ()
  "Test that later modifiers override earlier ones."
  (let ((task (falcon-task-create
               :name "precedence-test"
               :parameters '((temperature . 0.1) (max-tokens . 100)))))

    ;; Push modifiers in order of increasing precedence
    (falcon-task-push-modifier task 'low '((temperature . 0.5)))
    (falcon-task-push-modifier task 'medium '((temperature . 0.7) (style . "normal")))
    (falcon-task-push-modifier task 'high '((temperature . 0.9) (style . "detailed")))

    (let ((active-params (falcon-task-get-active-parameters task)))
      ;; High precedence should win
      (should (equal (alist-get 'temperature active-params) 0.9))
      (should (equal (alist-get 'style active-params) "detailed"))
      ;; Base parameter not overridden should remain
      (should (equal (alist-get 'max-tokens active-params) 100)))))

(ert-deftest test-falcon-task-prevent-empty-modifiers ()
  "Test that empty modifiers are not added to stack."
  (let ((task (falcon-task-create :name "test")))
    ;; Try to push nil modifier
    (falcon-task-push-modifier task 'empty nil)
    (should (equal (falcon-task-modifiers task) nil))

    ;; Try to push empty alist
    (falcon-task-push-modifier task 'empty '())
    (should (equal (falcon-task-modifiers task) nil))

    ;; Try to add modifier with no parameters
    (falcon-task-add-modifier task 'test)
    (should (equal (falcon-task-modifiers task) nil))

    ;; Valid modifier should still work
    (falcon-task-push-modifier task 'valid '((temperature . 0.7)))
    (should (equal (length (falcon-task-modifiers task)) 1))))


(provide 'falcon-test)
;;; falcon-test.el ends here
