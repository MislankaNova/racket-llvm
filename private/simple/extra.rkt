#lang racket/base

(require
 racket/contract
 "aggregate.rkt"
 "parameters.rkt"
 "memory.rkt"
 "globals.rkt"
 "convertible.rkt"
 "modules.rkt"
 "memory.rkt"
 "predicates.rkt"
 "references.rkt"
 "types.rkt"
 "builder.rkt"
 "functions.rkt"
 "misc-instructions.rkt"
 "../ffi/safe.rkt"
 (only-in "../ffi/ctypes.rkt" set-safe:llvm-builder-ref-module!)
 (for-syntax racket/base syntax/parse racket/syntax racket/list racket/function))


(provide llvm-if llvm-for llvm-when llvm-unless llvm-loop
         llvm-declare-function
         llvm-define-global 
         llvm-define-function llvm-define-module
         llvm-define-struct
         llvm-implement-function 
         enter-module/32 define-basic-block
         llvm:box)


(define-syntax (enter-module/32 stx)
 (syntax-case stx ()
  ((_ context-expr module-expr body bodies ...)
   #'(let ((context context-expr)
           (module module-expr))
      (parameterize ((current-module module)
                     (current-context context)
                     (current-builder (llvm-create-builder #:context context))
                     (current-integer-type (llvm-int32-type #:context context)))
       body bodies ...)))))



(define-syntax (define-basic-block stx)
 (syntax-case stx ()
  ((_ id ...)
   (with-syntax ((((id name) ...)
    (for/list ((id (syntax->list #'(id ...))))
     (list id (symbol->string (syntax-e id))))))
    #`(begin
       (define id (llvm-add-block #:name name)) ...)))))

(define (llvm-get-terminator (block (llvm-get-insert-block)))
  (LLVMGetBasicBlockTerminator block))


(define-syntax (llvm-maybe stx)
 (syntax-parse stx
  ((_ expr:expr ...)
   #'(unless (llvm-get-terminator)
       expr ...))))


(define-syntaxes (llvm-when llvm-unless)
 (let ()
  (define (maker which)
   (lambda (stx)
    (syntax-parse stx
     ((_ cond-expr:expr then-expr:expr ...)
      #`(let ()
          (define-basic-block then-block end-block)
          (define br-val cond-expr)
          #,(if which
                #'(llvm-cond-br br-val then-block end-block)
                #'(llvm-cond-br br-val end-block then-block))
   
          (llvm-set-position then-block)
          (let () then-expr ...)
          (llvm-maybe
            (llvm-br end-block))
   
          (llvm-set-position end-block)
          (void))))))
  (values (maker #t) (maker #f))))




(define-syntax (llvm-if stx)
 (syntax-parse stx
  ((_ cond-expr:expr then-expr:expr else-expr:expr)
   #'(let ()
       (define-basic-block then-block else-block merge-block)
       (define br-val cond-expr)
       (llvm-cond-br br-val then-block else-block)

       (llvm-set-position then-block)
       (define then-val then-expr)
       (define then-end-block (llvm-get-insert-block))
       (cond
         [(llvm-get-terminator)
          (set! then-end-block #f)]
         [else
          (llvm-br merge-block)])
       
       (llvm-set-position else-block)
       (define else-val else-expr)
       (define else-end-block (llvm-get-insert-block))
       (cond
         [(llvm-get-terminator)
          (set! else-end-block #f)]
         [else
          (llvm-br merge-block)])

       (llvm-set-position merge-block)
       (define merge-val (llvm-phi (value->llvm-type else-val)))
       (when then-end-block
        (llvm-add-incoming merge-val
             (cons then-val then-end-block)))
       (when else-end-block
        (llvm-add-incoming merge-val
             (cons else-val else-end-block)))
       merge-val))))


(define-syntax (llvm-for stx)
  (syntax-parse stx
   ((_ var:id init:expr test:expr inc:expr bodies:expr ...)
    #'(llvm-loop for-loop ((var init))
        (llvm-when test 
          (let () bodies ...)
          (for-loop inc))))))

(define (llvm:box v)
  (define ptr (llvm-alloca (value->llvm-type v)))
  (llvm-store v ptr)
  ptr)

(define-syntax (llvm-define-struct stx)
 (define-splicing-syntax-class packed
  (pattern (~seq) #:attr val #'#f)
  (pattern (~seq #:packed) #:attr val #'#t))
 (define-splicing-syntax-class omit-constructor
  (pattern (~seq) #:attr val #f)
  (pattern (~seq #:omit-constructor) #:attr val #t))
 (syntax-parse stx
  ((_ name:id ((field:id type:expr) ...) packed:packed omit-constructor:omit-constructor)
   (define (merge . args)
     (datum->syntax #'name (string->symbol (apply string-append (map ->string args))) #'name #'name))
   (define (->string v)
     (cond
       ((identifier? v) (symbol->string (syntax-e v)))
       ((symbol? v) (symbol->string v))))
   (define/with-syntax constructor (merge 'make- #'name))
   (define/with-syntax (type-val ...) (generate-temporaries #'(type ...)))
   (define/with-syntax (pointer-acc ...) (map (curry merge #'name '*-) (syntax->list #'(field ...))))
   (define/with-syntax (reference-acc ...) (map (curry merge #'name '&-) (syntax->list #'(field ...))))
   (define/with-syntax (struct-acc ...) (map (curry merge #'name '-) (syntax->list #'(field ...))))
   (define/with-syntax (struct-mut ...) (map (curry merge 'set- #'name '-) (syntax->list #'(field ...))))
   (define/with-syntax (index ...) (build-list (length (syntax->list #'(field ...))) identity))
   (define/with-syntax define-constructor
      (if (attribute omit-constructor.val)
          #'(begin)
          #'(define/contract (constructor field ...)
              (-> (llvm:type/c type-val) ... llvm:value?)
              (llvm-struct field ...))))


   #'(begin
       (define type-val type) ...
       (define name (llvm-struct-type type-val ... #:packed packed.val))
       define-constructor
       (define/contract (struct-acc s)
         (-> (llvm:type/c name) llvm:value?)
         (llvm-extract-value s index)) ...
       (define/contract (struct-mut s val)
         (-> (llvm:type/c name) (llvm:type/c type-val) llvm:value?)
         (llvm-insert-value s val index)) ...
       (define/contract (pointer-acc p)
         (-> (llvm:type/c (llvm-pointer-type name)) llvm:reference?)
         (llvm:reference (llvm-gep0 p index))) ...
       (define/contract (reference-acc p)
         (-> (llvm:reference/c name) llvm:reference?)
         (llvm:reference (llvm-gep0 (llvm:reference-pointer p) index))) ...
       ))))

(define-syntax (llvm-declare-function stx)
 (define-splicing-syntax-class visibility
  (pattern (~seq) #:attr val #f)
  (pattern (~seq #:visibility val:expr)))
 (define-splicing-syntax-class linkage
  (pattern (~seq) #:attr val #f)
  (pattern (~seq #:linkage val:expr)))
 (syntax-parse stx
  ((_ name:id type:expr visibility:visibility linkage:linkage)
   #`(begin
      (define name (llvm-add-function type (symbol->string 'name)))
      #,(if (attribute visibility.val)
          #'(llvm:set-visibility! name visibility.val)
          #'(begin))
      #,(if (attribute linkage.val)
          #'(llvm:set-linkage! name linkage.val)
          #'(begin))))))

(define-syntax (llvm-implement-function stx)
 (syntax-parse stx
  ((_ name:id (args:id ...) bodies:expr ...)
   (with-syntax (((indicies ...)
                  (for/list ((arg (syntax->list #'(args ...)))
                             (i (in-naturals)))
                    i)))
   #'(let ()
      (define entry-block (llvm-add-block-to-function name #:name "entry")) 
      (llvm-set-position entry-block)
      (define args (llvm-get-param indicies)) ...
      bodies ...
      (void))))))

    
(define-syntax (llvm-define-function stx)
 (define-splicing-syntax-class visibility
  (pattern (~seq))
  (pattern (~seq #:visibility val:expr)))
 (define-splicing-syntax-class linkage
  (pattern (~seq))
  (pattern (~seq #:linkage val:expr)))

 (syntax-parse stx
  ((_ name:id ((arg:id arg-type:expr) ... (~datum ->) return-type:expr)
      (~and
        (~seq keywords ...)
        (~seq visibility:visibility
              linkage:linkage))
      bodies:expr ...)
   (with-syntax (((arg-type-val ...) (generate-temporaries #'(arg-type ...))))
    (define/with-syntax function-implementation
      (syntax-property 
       #'(llvm-implement-function name (arg ...) bodies ...)
       'llvm-implement-function #t))

    #`(begin
       (define arg-type-val arg-type) ...
       (define return-type-val return-type)
       (llvm-declare-function name
         (llvm-function-type return-type-val arg-type-val ...)
         keywords ...)
       function-implementation)))))

(define-syntax (handle-bodies stx)
 (syntax-case stx ()
  ((_ (last-bodies ...) body bodies ...)
   (let () 
     (define new-body (local-expand #'body (syntax-local-context) #f))
     (if (syntax-property new-body 'llvm-implement-function)
         #`(handle-bodies (#,new-body last-bodies ...) bodies ...)
         (syntax-case new-body (begin)
          ((begin form ...)
            #'(handle-bodies (last-bodies ...) form ... bodies ...))
          (form 
            #'(begin form
               (handle-bodies (last-bodies ...) bodies ...)))))))
  ((_ (last-bodies ...)) #'(begin last-bodies ...))))

(define-syntax (llvm-define-module stx)
 (define-splicing-syntax-class context
  (pattern (~seq)))
 (define-splicing-syntax-class exports
  (pattern (~seq) #:attr (export 1) empty)
  (pattern (~seq #:exports (export:id ...))))
 (define-splicing-syntax-class int-type
  (pattern (~seq)))
 (define-splicing-syntax-class float-type
  (pattern (~seq)))


 (syntax-parse stx
  ((_ module-name:id context:context exports:exports int-type:int-type float-type:float-type
      bodies:expr ...)
   (define/with-syntax (renamed-exports ...) (generate-temporaries #'(exports.export ...)))
   #'(begin
       (define ctx (llvm-create-context))
       (define exports.export #f) ...
       (define-syntax renamed-exports (make-rename-transformer #'exports.export)) ...
       (define module-name (llvm-create-module (symbol->string 'module-name) #:context ctx))
       (parameterize ((current-context ctx)
                      (current-module module-name)
                      (current-integer-type (llvm-int32-type #:context ctx))
                      (current-float-type (llvm-double-type #:context ctx))
                      (current-builder (llvm-create-builder #:context ctx)))
         (set-safe:llvm-builder-ref-module! (current-builder) module-name)
         (handle-bodies () bodies ...)
         (set! renamed-exports exports.export) ...
         (void))))))


(define-syntax (llvm-define-global stx)
 (syntax-parse stx
  ((_ name:id init:expr)
   (define/with-syntax name-string (symbol->string (syntax-e #'name)))
   #'(begin
       (define value init)
       (define name (llvm-add-global (value->llvm-type value) name-string))
       (llvm:set-initializer! name value)))))

(define-syntax (llvm-loop stx)
  (syntax-parse stx
   ((_ name:id ((arg:id init:expr) ...) bodies:expr ...)
    (define/with-syntax (arg2 ...) (generate-temporaries #'(arg ...)))
    (define/with-syntax (arg-string ...)
     (map (compose symbol->string syntax-e) (syntax->list #'(arg ...))))
    (define/with-syntax (arg-value ...) (generate-temporaries #'(arg ...)))
    (define/with-syntax block-name (string-append "begin-" (symbol->string (syntax-e #'name))))

    #'(let ((arg-value init) ...)
       (define incoming-block (llvm-get-insert-block))
       (define begin-block (llvm-add-block #:name block-name))
       (llvm-br begin-block)
       (llvm-set-position begin-block)
       (define (name #:builder (builder (current-builder)) arg2 ...) 
         (let ((current-block (llvm-get-insert-block #:builder builder)))
          (llvm-add-incoming arg (cons arg2 current-block)) ...
          (llvm-br begin-block #:builder builder)))
       (define arg (llvm-phi (value->llvm-type arg-value) #:name arg-string)) ...
       (llvm-add-incoming arg (cons arg-value incoming-block)) ...
       bodies ...))))


