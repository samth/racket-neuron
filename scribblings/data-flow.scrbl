#lang scribble/doc

@(require "base.rkt")

@title{Data Flow}

@(defmodule neuron/data-flow #:packages ("neuron"))

@section{Input and Output}

@defproc[(port-sink [out-port output-port?]) process?]{
  Returns a @tech{sink} that writes byte strings to @racket[out-port]. Stops
  when given @racket[eof]. Closes @racket[out-port] when it stops. Dies when
  @racket[out-port] closes.

  Commands:

  @itemlist[
    @item{@racket['output-port] -- returns @racket[out-port]}
  ]

  @examples[
    #:eval neuron-evaluator
    (define snk (port-sink (open-output-string)))
    (void
     (give snk #"123")
     (give snk #"ab")
     (give snk eof))
    (get-output-string (snk 'output-port))
  ]
}

@defproc[(port-source [amt exact-nonnegative-integer?]
                      [in-port input-port?]
                      ) process?]{
  Returns a @tech{source} that reads byte strings from @racket[in-port] of
  length up to @racket[amt] bytes. Stops when @racket[in-port] reaches
  @racket[eof]. Dies when @racket[in-port] closes.

  Commands:

  @itemlist[
    @item{@racket['input-port] -- returns @racket[in-port]}
  ]

  @examples[
    #:eval neuron-evaluator
    (define src (port-source 3 (open-input-bytes #"123ab")))
    (recv src)
    (recv src)
    (recv src)
  ]
}

@defproc[(port-socket [amt exact-nonnegative-integer?]
                      [in-port input-port?]
                      [out-port output-port?]
                      ) process?]{
  Returns a @tech{socket} with source @racket[(port-source amt in-port)] and
  sink @racket[(port-sink out-port)].
}

@section{Decoding and Encoding Bytes}

A @deftech{parser} is ...

A @deftech{printer} is ...

A @deftech{codec type} is ...

@defthing[parser/c contract?]{
  Use this contract to indicate that some function is a @tech{parser}.
}

@defthing[printer/c contract?]{
  Use this contract to indicate that some function is a @tech{printer}.
}

@defproc[(decoder [prs parser/c]
                  [in-port input-port?]
                  ) process?]{
  Returns a @deftech{decoder} @tech{source}. Calls @racket[(emit (prs
  in-port))] until @racket[prs] returns @racket[eof]. Closes @racket[in-port]
  when it stops. Dies when @racket[in-port] closes.

  Commands:

  @itemlist[
    @item{@racket['parser] -- returns @racket[prs]}
    @item{@racket['input-port] -- returns @racket[in-port]}
  ]

  @examples[
    #:eval neuron-evaluator
    (define dec (decoder read (open-input-string "123 abc")))
    (recv dec)
    (recv dec)
    (recv dec)
  ]
}

@defproc[(encoder [prn printer/c]
                  [out-port output-port?]
                  ) process?]{
  Returns an @deftech{encoder} @tech{sink}. Calls @racket[(prn (take)
  out-port)] until it takes @racket[eof]. Closes @racket[out-port] when it
  stops. Dies when @racket[out-port] closes.

  Commands

  @itemlist[
    @item{@racket['printer] -- returns @racket[prn]}
    @item{@racket['output-port] -- returns @racket[out-port]}
  ]

  @examples[
    #:eval neuron-evaluator
    (define enc (encoder writeln (open-output-string)))
    (give enc 123)
    (give enc 'abc)
    (give enc eof)
    (get-output-string (enc 'output-port))
  ]
}

@defproc[(codec [prs parser/c]
                [prn printer/c]
                [in-port input-port?]
                [out-port output-port?]
                ) process?]{
  Returns a @deftech{codec} @tech{socket} with @tech{source} @racket[(encoder
  prn out-port)] and @tech{sink} @racket[(decoder prs in-port)].

  Commands:

  @itemlist[
    @item{@racket['decoder] -- returns the @tech{decoder} built from
      @racket[prs] and @racket[in-port].}
    @item{@racket['encoder] -- returns the @tech{encoder} built from
      @racket[prn] and @racket[out-port].}
  ]

  @examples[
    #:eval neuron-evaluator
    (define cdc
      (codec read writeln
             (open-input-string "123 abc")
             (open-output-string)))
    (void
     (give cdc 987)
     (give cdc 'zyx)
     (give cdc eof))
    (recv cdc)
    (recv cdc)
    (recv cdc)
    (get-output-string ((cdc 'encoder) 'output-port))
  ]
}

@defproc[(make-codec-type [name symbol?]
                          [prs parser/c]
                          [prn printer/c]
                          ) (values (-> input-port? process?)
                                    (-> output-port? process?)
                                    (-> input-port? output-port? process?))]{
  Creates a new @tech{codec type}. The @racket[name] argument is used as the
  type name.

  The result of @racket[make-codec-type] is three values:

  @itemlist[
    @item{a @tech{decoder} constructor for @tech{parser} @racket[prs],}
    @item{an @tech{encoder} constructor for @tech{printer} @racket[prn],}
    @item{a @tech{codec} constructor for @tech{parser} @racket[prs] and
      @tech{printer} @racket[prn].}
  ]
}

@defform[(define-codec name prs prn)]{
  Creates a new @tech{codec type} and binds variables related to the
  @tech{codec type}.

  A @racket[define-codec] form defines 5 names:

  @itemlist[
    @item{@racket[name]@racketidfont{-parser}, an alias for @tech{parser}
      @racket[prs].}
    @item{@racket[name]@racketidfont{-printer}, an alias for @tech{printer}
      @racket[prn].}
    @item{@racket[name]@racketidfont{-decoder}, a @tech{decoder} constructor
      for @tech{parser} @racket[prs].}
    @item{@racket[name]@racketidfont{-encoder}, an @tech{encoder} constructor
      for @tech{printer} @racket[prn].}
    @item{@racket[name]@racketidfont{-codec}, a @tech{codec} constructor for
      @tech{parser} @racket[prs] and @tech{printer} @racket[prn].}
  ]
}

@section{Codecs}

@deftogether[(@defproc[(line-parser [in-port input-port?]) any/c]
              @defproc[(line-printer [out-port output-port?]) any/c]
              @defproc[(line-decoder [in-port input-port?]) process?]
              @defproc[(line-encoder [out-port output-port?]) process?]
              @defproc[(line-codec [in-port input-port?]
                                   [out-port output-port?]) process?])]{
  Line @tech{codec type}.

  @examples[
    #:eval neuron-evaluator
    (define cdc (line-codec (open-input-string "123 abc\n")
                            (open-output-string)))
    (recv cdc)
    (give cdc "987 zyx")
    (get-output-string ((cdc 'encoder) 'output-port))
  ]
}

@deftogether[(@defproc[(sexp-parser [in-port input-port?]) any/c]
              @defproc[(sexp-printer [out-port output-port?]) any/c]
              @defproc[(sexp-decoder [in-port input-port?]) process?]
              @defproc[(sexp-encoder [out-port output-port?]) process?]
              @defproc[(sexp-codec [in-port input-port?]
                                   [out-port output-port?]) process?])]{
  S-expression @tech{codec type}.

  @examples[
    #:eval neuron-evaluator
    (define cdc (sexp-codec (open-input-string "(#hasheq((ab . 12)) 34)")
                            (open-output-string)))
    (recv cdc)
    (give cdc '(987 zyx))
    (get-output-string ((cdc 'encoder) 'output-port))
  ]
}

@deftogether[(@defproc[(json-parser [in-port input-port?]) any/c]
              @defproc[(json-printer [out-port output-port?]) any/c]
              @defproc[(json-decoder [in-port input-port?]) process?]
              @defproc[(json-encoder [out-port output-port?]) process?]
              @defproc[(json-codec [in-port input-port?]
                                   [out-port output-port?]) process?])]{
  @other-doc['(lib "json/json.scrbl")] @tech{codec type}.

  @examples[
    #:eval neuron-evaluator
    (define cdc (json-codec (open-input-string "[{\"ab\":12},34]")
                            (open-output-string)))
    (recv cdc)
    (give cdc '(98 #hasheq([zy . 76])))
    (get-output-string ((cdc 'encoder) 'output-port))
  ]
}

@section{File system}

@section{Network}
@subsection{TCP}
@subsection{UDP}
