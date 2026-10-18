;;; dicionariolatino-mode.el --- Edit dicionariolatino RDF/XML -*- lexical-binding: t -*-

;;; Commentary:
;; Major mode for dicionariolatino RDF/XML.  The buffer IS the XML
;; text, edited directly.  Saving writes the changes to disk;
;; `before-save-hook' refuses to save malformed XML (checked with
;; the built-in libxml parser).
;;
;; Bindings:
;;   C-c C-j   jump to a word (fuzzy, via completing-read)
;;   C-c C-h   search a hash (via occur)
;;   C-c C-n   next occurrence of current word
;;   C-c C-d   diff buffer vs. file
;;   M-g i     imenu (words + hashes)

;;; Code:

(require 'hideshow)

(defconst dicionariolatino--lemma-re
  "<lex:lemma[^>]*>\\([^<]+\\)</lex:lemma>"
  "Regex matching a lemma; capture group 1 is the word.")

(defvar dicionariolatino-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-j") #'dicionariolatino-jump-to-word)
    (define-key map (kbd "C-c C-h") #'dicionariolatino-search-hash)
    (define-key map (kbd "C-c C-n") #'dicionariolatino-next-word)
    (define-key map (kbd "C-c C-d") #'dicionariolatino-diff)
    (define-key map (kbd "C-c C-v") #'dicionariolatino-split-view)
    map))

(defun dicionariolatino--all-words ()
  "Return a sorted list of unique lemmas in the buffer."
  (save-excursion
    (goto-char (point-min))
    (let (words)
      (while (re-search-forward dicionariolatino--lemma-re nil t)
        (push (match-string 1) words))
      (sort (delete-dups words) #'string<))))

(defun dicionariolatino-jump-to-word (word)
  "Prompt for WORD and jump to its entry."
  (interactive (list (completing-read "Word: " (dicionariolatino--all-words) nil t)))
  (goto-char (point-min))
  (if (re-search-forward (concat "<lex:lemma[^>]*>"
                                 (regexp-quote word) "</lex:lemma>") nil t)
      (beginning-of-line)
    (user-error "Not found: %s" word)))

(defun dicionariolatino-search-hash (hash)
  "List (via `occur') all lines containing HASH."
  (interactive "sHash: ")
  (occur (regexp-quote hash)))

(defun dicionariolatino--current-word ()
  "Return the lemma nearest before point, or nil."
  (save-excursion
    (when (re-search-backward dicionariolatino--lemma-re nil t)
      (match-string 1))))

(defun dicionariolatino-next-word ()
  "Move to the next entry with the same lemma as the current one."
  (interactive)
  (let ((word (or (dicionariolatino--current-word)
                  (user-error "Point is before any lemma"))))
    (if (re-search-forward (concat "<lex:lemma[^>]*>"
                                   (regexp-quote word) "</lex:lemma>") nil t)
        (beginning-of-line)
      (message "No further occurrence of %s" word))))

(defun dicionariolatino-diff ()
  "Show diff between the buffer and its file."
  (interactive)
  (diff-buffer-with-file (current-buffer)))

(defun dicionariolatino--check-xml ()
  "Refuse to save if the buffer is not well-formed XML."
  (condition-case err
      (libxml-parse-xml-region (point-min) (point-max))
    (error (user-error "XML not well-formed: %s"
                       (error-message-string err)))))

(defun dicionariolatino--entry-bounds ()
  "Retorna as posições (início . fim) da entrada atual."
  (save-excursion
    (when (re-search-backward "<lex:DictionaryEntry" nil t)
      (let ((start (match-beginning 0)))
        (when (re-search-forward "</lex:DictionaryEntry>" nil t)
          (cons start (match-end 0)))))))

(defun dicionariolatino-split-view ()
  "Divide a tela: esquerda para edição focada, direita para o XML completo."
  (interactive)
  (let ((bounds (dicionariolatino--entry-bounds)))
    (unless bounds
      (user-error "Cursor não está dentro de uma <lex:DictionaryEntry>"))
    (let ((start (car bounds))
          (end (cdr bounds)))
      
      ;; 1. Divide a tela
      (delete-other-windows)
      (split-window-right)
      
      ;; 2. Janela da direita: XML completo focado na entrada
      (other-window 1)
      (goto-char start)
      (recenter 0)
      
      ;; 3. Janela da esquerda: Edição Focada (Indirect Buffer)
      (other-window 1)
      (let ((indirect (clone-indirect-buffer "*dicionariolatino-entry*" nil t)))
        (switch-to-buffer indirect)
        (narrow-to-region start end)
        (hs-minor-mode 1)                ;; Permite colapsar as tags XML
        (hs-hide-all)                    ;; Esconde as tags para ficar limpo
        
        ;; 4. Header dinâmico com Palavra e Hash
        (setq-local header-line-format
                    '(:eval (save-excursion
                              (goto-char (point-min))
                              (format " Word: %s | Hash: %s"
                                      (or (and (re-search-forward dicionariolatino--lemma-re nil t) 
                                               (match-string 1)) "?")
                                      (or (and (re-search-forward "<dcterms:identifier>\\([^<]+\\)" nil t) 
                                               (match-string 1)) "?")))))))))

;;;###autoload
(define-derived-mode dicionariolatino-mode xml-mode "Dicionariolatino"
  "Major mode for editing dicionariolatino RDF/XML dumps."
  (setq-local imenu-generic-expression
              `(("Words"  ,dicionariolatino--lemma-re 1)
                ("Hashes" "^\\s-*<lex:DictionaryEntry rdf:about=\"\\([^\"]+\\)\"" 1)))
  (add-hook 'before-save-hook #'dicionariolatino--check-xml nil t))

;;;###autoload
(add-to-list 'auto-mode-alist
             '("/dicionariolatino[^/]*\\.xml\\'" . dicionariolatino-mode))

(provide 'dicionariolatino-mode)
;;; dicionariolatino-mode.el ends here
;;; dicionariolatino-mode.el ends here
