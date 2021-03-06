#lang racket

(require
  "define.rkt"
  "ctypes.rkt")

(require ffi/unsafe)

(provide (all-defined-out))



;/*===-- Pass Registry -----------------------------------------------------===*/

;/** Return the global pass registry, for use with initialization functions.
;    See llvm::PassRegistry::getPassRegistry. */
(define-llvm-unsafe LLVMGetGlobalPassRegistry
 (_fun -> LLVMPassRegistryRef))


;/*===-- Pass Managers -----------------------------------------------------===*/

;/** Constructs a new whole-module pass pipeline. This type of pipeline is
;    suitable for link-time optimization and whole-module transformations.
;    See llvm::PassManager::PassManager. */
(define-llvm-unsafe LLVMCreatePassManager (_fun -> LLVMPassManagerRef))

;/** Constructs a new function-by-function pass pipeline over the module
;    provider. It does not take ownership of the module provider. This type of
;    pipeline is suitable for code generation and JIT compilation tasks.
;    See llvm::FunctionPassManager::FunctionPassManager. */
(define-llvm-unsafe LLVMCreateFunctionPassManagerForModule (_fun LLVMModuleRef -> LLVMPassManagerRef))


;/** Initializes, executes on the provided module, and finalizes all of the
;    passes scheduled in the pass manager. Returns 1 if any of the passes
;    modified the module, 0 otherwise. See llvm::PassManager::run(Module&). */
(define-llvm-unsafe LLVMRunPassManager (_fun LLVMPassManagerRef LLVMModuleRef -> LLVMBool))

;/** Initializes all of the function passes scheduled in the function pass
;    manager. Returns 1 if any of the passes modified the module, 0 otherwise.
;    See llvm::FunctionPassManager::doInitialization. */
(define-llvm-unsafe LLVMInitializeFunctionPassManager (_fun LLVMPassManagerRef -> LLVMBool))

;/** Executes all of the function passes scheduled in the function pass manager
;    on the provided function. Returns 1 if any of the passes modified the
;    function, false otherwise.
;    See llvm::FunctionPassManager::run(Function&). */
(define-llvm-unsafe LLVMRunFunctionPassManager (_fun LLVMPassManagerRef LLVMValueRef -> LLVMBool))

;/** Finalizes all of the function passes scheduled in in the function pass
;    manager. Returns 1 if any of the passes modified the module, 0 otherwise.
;    See llvm::FunctionPassManager::doFinalization. */
(define-llvm-unsafe LLVMFinalizeFunctionPassManager (_fun LLVMPassManagerRef -> LLVMBool))

;/** Frees the memory of a pass pipeline. For function pipelines, does not free
;    the module provider.
;    See llvm::PassManagerBase::~PassManagerBase. */
(define-llvm-unsafe LLVMDisposePassManager (_fun LLVMPassManagerRef -> _void))


;Analysis
(define LLVMVerifierFailureAction (_enum '(
  LLVMAbortProcessAction    ;/* verifier will print to stderr and abort() */
  LLVMPrintMessageAction    ;/* verifier will print to stderr and return 1 */
  LLVMReturnStatusAction))) ;/* verifier will just return 1 */


;/* Verifies that a module is valid, taking the specified action if not.
;   Optionally returns a human-readable description of any invalid constructs.
;   OutMessage must be disposed with LLVMDisposeMessage. */

(define-llvm-unsafe LLVMVerifyModule
   (_fun (module action) ::
          (module : LLVMModuleRef)
          (action : LLVMVerifierFailureAction)
          (message : (_ptr io LLVMMessage) = #f)
          ->
          (ans : LLVMBool)
          ->
          (and ans message)))


(define-llvm-safe LLVMVerifyModule
   (_fun (module action) ::
          (module : safe:LLVMModuleRef)
          (action : LLVMVerifierFailureAction)
          (message : (_ptr io LLVMMessage) = #f)
          ->
          (ans : LLVMBool)
          ->
          (and ans message)))



;/* Verifies that a single function is valid, taking the specified action. Useful
;   for debugging. */
(define-llvm-unsafe LLVMVerifyFunction (_fun LLVMValueRef LLVMVerifierFailureAction -> LLVMBool))

;/* Open up a ghostview window that displays the CFG of the current function.
;   Useful for debugging. */

(define-llvm-unsafe LLVMViewFunctionCFG (_fun LLVMValueRef -> _void))
(define-llvm-unsafe LLVMViewFunctionCFGOnly (_fun LLVMValueRef -> _void))


(define-llvm-unsafe LLVMInitializeCore (_fun LLVMPassRegistryRef -> _void))

