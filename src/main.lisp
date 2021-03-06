(in-package #:pgloader)

(defun list-encodings ()
  "List known encodings names and aliases from charsets::*lisp-encodings*."
  (format *standard-output* "Name    ~30TAliases~%")
  (format *standard-output* "--------~30T--------------~%")
  (loop
     with encodings = (sort (copy-tree charsets::*lisp-encodings*) #'string<
			    :key #'car)
     for (name . aliases) in encodings
     do (format *standard-output* "~a~30T~{~a~^, ~}~%" name aliases))
  (terpri))

(defun log-threshold (min-message &key quiet verbose debug)
  "Return the internal value to use given the script parameters."
  (cond (debug   :debug)
	(verbose :info)
	(quiet   :warning)
	(t       (or (find-symbol (string-upcase min-message) "KEYWORD")
		     :notice))))

(defparameter *opt-spec*
  `((("help" #\h) :type boolean :documentation "Show usage and exit.")

    (("version" #\V) :type boolean
     :documentation "Displays pgloader version and exit.")

    (("quiet"   #\q) :type boolean :documentation "Be quiet")
    (("verbose" #\v) :type boolean :documentation "Be verbose")
    (("debug"   #\d) :type boolean :documentation "Display debug level information.")

    ("client-min-messages" :type string :initial-value "warning"
			   :documentation "Filter logs seen at the console")

    ("log-min-messages" :type string :initial-value "notice"
			:documentation "Filter logs seen in the logfile")

    (("root-dir" #\D) :type string :initial-value ,*root-dir*
                      :documentation "Output root directory.")

    (("upgrade-config" #\U) :type boolean
     :documentation "Output the command(s) corresponding to .conf file for v2.x")

    (("list-encodings" #\E) :type boolean
     :documentation "List pgloader known encodings and exit.")

    (("logfile" #\L) :type string
     :documentation "Filename where to send the logs.")

    (("load" #\l) :type string :list t :optional t
     :documentation "Read user code from file")))

(defun print-backtrace (condition debug stream)
  "Depending on DEBUG, print out the full backtrace or just a shorter
   message on STREAM for given CONDITION."
  (if debug
      (trivial-backtrace:print-backtrace condition :output stream :verbose t)
      (trivial-backtrace:print-condition condition stream)))

(defun mkdir-or-die (path debug &optional (stream *standard-output*))
  "Create a directory at given PATH and exit with an error message when
   that's not possible."
  (handler-case
      (ensure-directories-exist path)
    (condition (e)
      ;; any error here is a panic
      (if debug
	  (print-backtrace e debug stream)
	  (format stream "PANIC: ~a.~%" e))
      (uiop:quit))))

(defun log-file-name (logfile)
  " If the logfile has not been given by the user, default to using
    pgloader.log within *root-dir*."
  (cond ((null logfile)
	 (make-pathname :directory (directory-namestring *root-dir*)
			:name "pgloader"
			:type "log"))

	((fad:pathname-relative-p logfile)
	 (merge-pathnames logfile *root-dir*))

	(t
	 logfile)))

(defun main (argv)
  "Entry point when building an executable image with buildapp"
  (let ((args (rest argv)))
    (multiple-value-bind (options arguments)
	(command-line-arguments:process-command-line-options *opt-spec* args)

      (destructuring-bind (&key help version quiet verbose debug logfile
				list-encodings upgrade-config load
				client-min-messages log-min-messages
				root-dir)
	  options

	;; First care about the root directory where pgloader is supposed to
	;; output its data logs and reject files
	(setf *root-dir* (fad:pathname-as-directory root-dir))
	(mkdir-or-die *root-dir* debug)

	;; Set parameters that come from the environement
	(init-params-from-environment)

	;; Then process options
	(when debug
	  (format t "sb-impl::*default-external-format* ~s~%"
		  sb-impl::*default-external-format*)
	  (format t "tmpdir: ~s~%" *default-tmpdir*))

	(when version
	  (format t "pgloader version ~s~%" *version-string*))

	(when help
	  (format t "~a [ option ... ] command-file ..." (first argv))
	  (command-line-arguments:show-option-help *opt-spec*))

	(when (or help version) (uiop:quit))

	(when list-encodings
	  (list-encodings)
	  (uiop:quit))

	(when upgrade-config
	  (loop for filename in arguments
	     do
	       (pgloader.ini:convert-ini-into-commands filename)
	       (format t "~%~%"))
	  (uiop:quit))

	(when load
	  (loop for filename in load
	     do (load (compile-file filename :verbose nil :print nil))))

	;; Now process the arguments
	(when arguments
	  ;; Start the logs system
	  (let ((logfile        (log-file-name logfile))
		(log-min-messages
		 (log-threshold log-min-messages
				:quiet quiet :verbose verbose :debug debug))
		(client-min-messages
		 (log-threshold client-min-messages
				:quiet quiet :verbose verbose :debug debug)))

	    (start-logger :log-filename logfile
			  :log-min-messages log-min-messages
			  :client-min-messages client-min-messages)

	    ;; tell the user where to look for interesting things
	    (log-message :log "Main logs in '~a'" logfile)
	    (log-message :log "Data errors in '~a'~%" *root-dir*))

	  ;; process the files
	  (loop for filename in arguments
	     do
	       ;; The handler-case is to catch unhandled exceptions at the
	       ;; top level and continue with the next file in the list.
	       ;;
	       ;; The handler-bind is to be able to offer a meaningful
	       ;; backtrace to the user in case of unexpected conditions
	       ;; being signaled.
	       (handler-case
		   (handler-bind
		       ((condition
			 #'(lambda (condition)
			     (log-message :fatal "We have a situation here.")
			     (print-backtrace condition debug *standard-output*))))

		     (run-commands (fad:canonical-pathname filename)
				   :start-logger nil)
		     (format t "~&"))

		 (condition (c)
		   (when debug (invoke-debugger c))
		   (uiop:quit 1)))))

	(uiop:quit)))))
