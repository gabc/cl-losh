(in-package :losh.control-flow)

(defmacro _ (expr &rest forms)
  "Thread the given forms, with `_` as a placeholder."
  ;; I am going to lose my fucking mind if I have to program lisp without
  ;; a threading macro, but I don't want to add another dep to this library, so
  ;; here we are.
  `(let* ((_ ,expr)
          ,@(mapcar (lambda (form)
                      (if (symbolp form)
                        `(_ (,form _))
                        `(_ ,form)))
                    forms))
     _))

(defmacro nest (&rest forms)
  "Thread the given forms, putting each as the body of the previous.

  Example:

    (nest (multiple-value-bind (a b c) (foo))
          (when (and a b c))
          (multiple-value-bind (d e f) (bar))
          (when (and d e f))
          (do-something))

  macroexpands to:

    (multiple-value-bind (a b c) (foo)
      (when (and a b c)
        (multiple-value-bind (d e f) (bar)
          (when (and d e f)
            (do-something)))))

  "
  ;; thanks, Fare
  (reduce (lambda (prefix body) `(,@prefix ,body))
          forms :from-end t))


(defmacro recursively (bindings &body body)
  "Execute `body` recursively, like Clojure's `loop`/`recur`.

  `bindings` should contain a list of symbols and (optional) starting values.

  In `body` the symbol `recur` will be bound to the function for recurring.

  This macro doesn't perform an explicit tail-recursion check like Clojure's
  `loop`.  You know what you're doing, right?

  Example:

      (defun length (some-list)
        (recursively ((list some-list)
                      (n 0))
          (if (null list)
            n
            (recur (cdr list) (1+ n)))))

  "
  (flet ((extract-var (binding)
           (if (atom binding) binding (first binding)))
         (extract-val (binding)
           (if (atom binding) nil (second binding))))
    `(labels ((recur ,(mapcar #'extract-var bindings)
                ,@body))
      (recur ,@(mapcar #'extract-val bindings)))))


(defmacro when-found ((var lookup-expr) &body body)
  "Perform `body` with `var` bound to the result of `lookup-expr`, when valid.

  `lookup-expr` should be an expression that returns two values, the first being
  the result (which will be bound to `var`) and the second indicating whether
  the lookup was successful.  The standard `gethash` is an example of a function
  that behaves like this.

  If the lookup was successful, `body` will be executed and its value returned.

  Example:

    (multiple-value-bind (val found) (gethash :foo hash)
      (when found
        body))

    ; becomes

    (when-found (val (gethash :foo hash))
      body)

  "
  (with-gensyms (found)
    `(multiple-value-bind (,var ,found) ,lookup-expr
       ;; We could preserve and pass along the value of found as a secondary
       ;; return value from the form, but that would kill potential last-call
       ;; optimization (and the ability to return multiple values from `body`).
       (when ,found
         ,@body))))

(defmacro if-found ((var lookup-expr) then else)
  "Perform `then` or `else` depending on the results of `lookup-expr`.

  `lookup-expr` should be an expression that returns two values, the first being
  the result and the second indicating whether the lookup was successful.  The
  standard `gethash` is an example of a function that behaves like this.

  If the lookup was successful, `then` will be executed with `var` bound to the
  result, and its value returned.

  Otherwise `else` will be executed and returned, without any extra bindings.

  Example:

    (multiple-value-bind (val found) (gethash :foo hash)
      (if found
        'yes
        'no))

    ; becomes

    (if-found (val (gethash :foo hash))
      'yes
      'no)

  "
  (with-gensyms (found result)
    `(multiple-value-bind (,result ,found) ,lookup-expr
      (if ,found
        (let ((,var ,result))
          ,then)
        ,else))))


(defmacro gathering (&body body)
  "Run `body` to gather some things and return a fresh list of them.

  `body` will be executed with the symbol `gather` bound to a function of one
  argument.  Once `body` has finished, a list of everything `gather` was called
  on will be returned.

  It's handy for pulling results out of code that executes procedurally and
  doesn't return anything, like `maphash` or Alexandria's `map-permutations`.

  The `gather` function can be passed to other functions, but should not be
  retained once the `gathering` form has returned (it would be useless to do so
  anyway).

  Examples:

    (gathering
      (dotimes (i 5)
        (gather i))
    =>
    (0 1 2 3 4)

    (gathering
      (mapc #'gather '(1 2 3))
      (mapc #'gather '(a b)))
    =>
    (1 2 3 a b)

  "
  (with-gensyms (result)
    `(let ((,result (make-queue)))
      (flet ((gather (item)
               (enqueue item ,result)
               item))
        ,@body)
      (queue-contents ,result))))

(defmacro gathering-vector ((&key (size 16) (element-type t)) &body body)
  "Run `body` to gather some things and return a fresh vector of them.

  `body` will be executed with the symbol `gather` bound to a function of one
  argument.  Once `body` has finished, a vector of everything `gather` was
  called on will be returned.  This vector will be adjustable and have a fill
  pointer.

  It's handy for pulling results out of code that executes procedurally and
  doesn't return anything, like `maphash` or Alexandria's `map-permutations`.

  The `gather` function can be passed to other functions, but should not be
  retained once the `gathering` form has returned (it would be useless to do so
  anyway).

  Examples:

    (gathering-vector ()
      (dotimes (i 5)
        (gather i))
    =>
    #(0 1 2 3 4)

    (gathering-vector ()
      (mapc #'gather '(1 2 3))
      (mapc #'gather '(a b)))
    =>
    #(1 2 3 a b)

  "
  (with-gensyms (result)
    `(let ((,result (make-array ,size :adjustable t :fill-pointer 0
                      :element-type ,element-type)))
       (flet ((gather (item)
                (vector-push-extend item ,result)
                item))
         ,@body)
       ,result)))


(defmacro when-let (bindings &body body)
  "Bind `bindings` in parallel and execute `body`, short-circuiting on `nil`.

  This macro combines `when` and `let`.  It takes a list of bindings and binds
  them like `let` before executing `body`, but if any binding's value evaluates
  to `nil` the process stops there and `nil` is immediately returned.

  Examples:

    (when-let ((a (progn (print :a) 1))
               (b (progn (print :b) 2))
               (c (progn (print :c) 3)))
      (list a b c))
    ; =>
    :A
    :B
    :C
    (1 2 3)

    (when-let ((a (progn (print :a) 1))
               (b (progn (print :b) nil))
               (c (progn (print :c) 3)))
      (list a b c))
    ; =>
    :A
    :B
    NIL

  "
  ;; (when-let ((a 1)
  ;;            (b 2))
  ;;   (+ a b))
  ;; =>
  ;; (BLOCK #:BLOCK632
  ;;   (LET ((A (OR 1 (RETURN-FROM #:BLOCK632)))
  ;;         (B (OR 2 (RETURN-FROM #:BLOCK632))))
  ;;     (+ A B)))
  (with-gensyms (block)
    `(block ,block
       (let (,@(loop :for (symbol value) :in bindings
                     :collect `(,symbol (or ,value (return-from ,block)))))
         ,@body))))

(defmacro when-let* (bindings &body body)
  "Bind `bindings` sequentially and execute `body`, short-circuiting on `nil`.

  This macro combines `when` and `let*`.  It takes a list of bindings and binds
  them like `let` before executing `body`, but if any binding's value evaluates
  to `nil` the process stops there and `nil` is immediately returned.

  Examples:

    (when-let* ((a (progn (print :a) 1))
                (b (progn (print :b) 2))
                (c (progn (print :c) 3)))
      (list a b c))
    ; =>
    :A
    :B
    :C
    (1 2 3)

    (when-let* ((a (progn (print :a) 1))
                (b (progn (print :b) nil))
                (c (progn (print :c) 3)))
      (list a b c))
    ; =>
    :A
    :B
    NIL

  "
  ;; (when-let* ((a 1)
  ;;             (b 2))
  ;;      (+ a b))
  ;; =>
  ;; (BLOCK #:BLOCK647
  ;;   (LET* ((A (OR 1 (RETURN-FROM #:BLOCK647)))
  ;;          (B (OR 2 (RETURN-FROM #:BLOCK647))))
  ;;     (+ A B)))
  (with-gensyms (block)
    `(block ,block
       (let* (,@(loop :for (symbol value) :in bindings
                      :collect `(,symbol (or ,value (return-from ,block)))))
         ,@body))))

(defmacro if-let (bindings &body body)
  "Bind `bindings` in parallel and execute `then` if all are true, or `else` otherwise.

  `body` must be of the form `(...optional-declarations... then else)`.

  This macro combines `if` and `let`.  It takes a list of bindings and binds
  them like `let` before executing the `then` branch of `body`, but if any
  binding's value evaluates to `nil` the process stops there and the `else`
  branch is immediately executed (with no bindings in effect).

  If any `optional-declarations` are included they will only be in effect for
  the `then` branch.

  Examples:

    (if-let ((a (progn (print :a) 1))
             (b (progn (print :b) 2))
             (c (progn (print :c) 3)))
      (list a b c)
      'nope)
    ; =>
    :A
    :B
    :C
    (1 2 3)

    (if-let ((a (progn (print :a) 1))
             (b (progn (print :b) nil))
             (c (progn (print :c) 3)))
      (list a b c)
      'nope)
    ; =>
    :A
    :B
    NOPE

  "
  (with-gensyms (outer inner)
    (multiple-value-bind (body declarations) (alexandria:parse-body body)
      (destructuring-bind (then else) body
        `(block ,outer
           (block ,inner
             (let ,(loop :for (symbol value) :in bindings
                         :collect `(,symbol (or ,value (return-from ,inner))))
               ,@declarations
               (return-from ,outer ,then)))
           ,else)))))

(defmacro if-let* (bindings &body body)
  "Bind `bindings` sequentially and execute `then` if all are true, or `else` otherwise.

  `body` must be of the form `(...optional-declarations... then else)`.

  This macro combines `if` and `let*`.  It takes a list of bindings and binds
  them like `let*` before executing the `then` branch of `body`, but if any
  binding's value evaluate to `nil` the process stops there and the `else`
  branch is immediately executed (with no bindings in effect).

  If any `optional-declarations` are included they will only be in effect for
  the `then` branch.

  Examples:

    (if-let* ((a (progn (print :a) 1))
              (b (progn (print :b) 2))
              (c (progn (print :c) 3)))
      (list a b c)
      'nope)
    ; =>
    :A
    :B
    :C
    (1 2 3)

    (if-let* ((a (progn (print :a) 1))
              (b (progn (print :b) nil))
              (c (progn (print :c) 3)))
      (list a b c)
      'nope)
    ; =>
    :A
    :B
    NOPE

  "
  (with-gensyms (outer inner)
    (multiple-value-bind (body declarations) (alexandria:parse-body body)
      (destructuring-bind (then else) body
        `(block ,outer
           (block ,inner
             (let* ,(loop :for (symbol value) :in bindings
                          :collect `(,symbol (or ,value (return-from ,inner))))
               ,@declarations
               (return-from ,outer ,then)))
           ,else)))))


(defmacro multiple-value-bind* (bindings &body body)
  "Bind each pair in `bindings` with `multiple-value-bind` sequentially.

  Example:

    (multiple-value-bind*
        (((a b) (values 0 1))
         ((c) (values (1+ b)))
      (list a b c))
    ; =>
    ; (0 1 2)

  From https://github.com/phoe/m-m-v-b

  "
  (if (null bindings)
    `(progn ,@body)
    (destructuring-bind ((vars form) &rest bindings) bindings
      `(multiple-value-bind ,vars ,form
         (multiple-value-bind* ,bindings ,@body)))))


(defmacro do-repeat (n &body body)
  "Perform `body` `n` times."
  `(dotimes (,(gensym) ,n)
     ,@body))

(defmacro do-vector
    ((var-or-vars vector &key (start nil start?) (end nil end?)) &body body)
  "Iterate over `vector`, performing `body` with `var-or-vars` bound.

  `var-or-vars` can be one of the following:

  * `value-symbol`
  * `(value-symbol)`
  * `(index-symbol value-symbol)`

  Successive elements of `vector` will be bound to `value-symbol` while `body`
  is executed.  If `index-symbol` is given, the current index will be bound to
  it.

  Returns `nil`.

  "
  (setf var-or-vars (alexandria:ensure-list var-or-vars)
        start (if start? start 0))
  (alexandria:once-only (vector start)
    (let ((i nil)
          (v nil)
          (end% (gensym "END")))
      (ecase (length var-or-vars)
        (1 (setf i (gensym "I")
                 v (first var-or-vars)))
        (2 (setf i (first var-or-vars)
                 v (second var-or-vars))))
      `(do ((,end% ,(if end? end `(length ,vector)))
            (,i ,start (1+ ,i)))
         ((>= ,i ,end%))
         (let ((,v (aref ,vector ,i)))
           ,@body)))))

(defmacro do-range (ranges &body body)
  "Perform `body` on the given `ranges`.

  Each range in `ranges` should be of the form `(variable from below)`.  During
  iteration `body` will be executed with `variable` bound to successive values
  in the range [`from`, `below`).

  `from` can be larger than `below`, in which case the values will be stepped
  down instead of up.

  If multiple ranges are given they will be iterated in a nested fashion.

  Example:

    (do-range ((x  0  6  2)
               (y 12 10))
      (pr x y))
    ; =>
    ; 0 12
    ; 0 11
    ; 2 12
    ; 2 11
    ; 4 12
    ; 4 11

  "
  (assert (not (null ranges)) ()
    "Ranges to iterate in DO-RANGE must not be null.")
  (recursively ((ranges ranges))
    (if (null ranges)
      `(progn ,@body)
      (destructuring-bind (var from to &optional by) (first ranges)
        (with-gensyms (cmp)
          (once-only (from to by)
            `(do ((,cmp (if ,by
                          (if (minusp ,by) #'<= #'>=)
                          (if (< ,from ,to) #'>= #'<=)))
                  (,by (or ,by (if (< ,from ,to) 1 -1)))
                  (,var ,from (+ ,var ,by)))
               ((funcall ,cmp ,var ,to))
               ,(recur (rest ranges)))))))))

(defmacro do-irange (ranges &body body)
  "Perform `body` on the given inclusive `ranges`.

  Each range in `ranges` should be of the form `(variable from to &optional by)`.
  During iteration `body` will be executed with `variable` bound to successive
  values according to `by` in the range [`from`, `to`].

  `from` can be larger than `to`, in which case the values will be stepped down
  instead of up.

  If multiple ranges are given they will be iterated in a nested fashion.

  Example:

    (do-irange ((x  0  4  2)
                (y 11 10))
      (pr x y))
    ; =>
    ; 0 11
    ; 0 10
    ; 2 11
    ; 2 10
    ; 4 11
    ; 4 10

  "
  (assert (not (null ranges)) ()
    "Ranges to iterate in DO-RANGE must not be null.")
  (recursively ((ranges ranges))
    (if (null ranges)
      `(progn ,@body)
      (destructuring-bind (var from to &optional by) (first ranges)
        (with-gensyms (cmp)
          (once-only (from to by)
            `(do ((,cmp (if ,by
                          (if (minusp ,by) #'< #'>)
                          (if (< ,from ,to) #'> #'<)))
                  (,by (or ,by (if (< ,from ,to) 1 -1)))
                  (,var ,from (+ ,var ,by)))
               ((funcall ,cmp ,var ,to))
               ,(recur (rest ranges)))))))))


(let ((eof (gensym "EOF")))
  (defmacro do-file
      ((symbol path &rest open-options &key (reader '#'read-line) &allow-other-keys)
       &body body)
    "Iterate over the contents of `file` using `reader`.

    During iteration, `symbol` will be set to successive values read from the
    file by `reader`.

    `reader` can be any function that conforms to the usual reading interface,
    i.e. anything that can handle `(read-foo stream eof-error-p eof-value)`.

    Any keyword arguments other than `:reader` will be passed along to `open`.

    If `nil` is used for one of the `:if-…` options to `open` and this results
    in `open` returning `nil`, no iteration will take place.

    An implicit block named `nil` surrounds the iteration, so `return` can be
    used to terminate early.

    Returns `nil`.

    Examples:

      (do-file (line \"foo.txt\")
        (print line))

      (do-file (form \"foo.lisp\" :reader #'read :external-format :EBCDIC-US)
        (when (eq form :stop)
          (return :stopped-early))
        (print form))

      (do-file (line \"does-not-exist.txt\" :if-does-not-exist nil)
        (this-will-not-be-executed))

    "
    (let ((open-options (alexandria:remove-from-plist open-options :reader)))
      (with-gensyms (stream)
        (once-only (path reader)
          `(when-let ((,stream (open ,path :direction :input ,@open-options)))
             (unwind-protect
                 (do ((,symbol
                       (funcall ,reader ,stream nil ',eof)
                       (funcall ,reader ,stream nil ',eof)))
                     ((eq ,symbol ',eof))
                   ,@body)
               (close ,stream))))))))
