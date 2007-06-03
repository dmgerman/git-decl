all::

# Define V=1 to have a more verbose compile.
#

GIT-VERSION-FILE: .FORCE-GIT-VERSION-FILE
	@$(SHELL_PATH) ./GIT-VERSION-GEN
-include GIT-VERSION-FILE

SCRIPT_SH = git-gui.sh
GITGUI_BUILT_INS = git-citool
ALL_PROGRAMS = $(GITGUI_BUILT_INS) $(patsubst %.sh,%,$(SCRIPT_SH))
ALL_LIBFILES = $(wildcard lib/*.tcl)
PRELOAD_FILES = lib/class.tcl

ifndef SHELL_PATH
	SHELL_PATH = /bin/sh
endif

ifndef gitexecdir
	gitexecdir := $(shell git --exec-path)
endif

ifndef sharedir
	sharedir := $(dir $(gitexecdir))share
endif

ifndef INSTALL
	INSTALL = install
endif

ifndef V
	QUIET_GEN      = @echo '   ' GEN $@;
	QUIET_BUILT_IN = @echo '   ' BUILTIN $@;
	QUIET_INDEX    = @echo '   ' INDEX $(dir $@);
	QUIET_2DEVNULL = 2>/dev/null
endif

TCL_PATH   ?= tclsh
TCLTK_PATH ?= wish

ifeq ($(findstring $(MAKEFLAGS),s),s)
QUIET_GEN =
QUIET_BUILT_IN =
endif

DESTDIR_SQ = $(subst ','\'',$(DESTDIR))
gitexecdir_SQ = $(subst ','\'',$(gitexecdir))
SHELL_PATH_SQ = $(subst ','\'',$(SHELL_PATH))
TCL_PATH_SQ = $(subst ','\'',$(TCL_PATH))
TCLTK_PATH_SQ = $(subst ','\'',$(TCLTK_PATH))

libdir   ?= $(sharedir)/git-gui/lib
libdir_SQ = $(subst ','\'',$(libdir))

exedir    = $(dir $(gitexecdir))share/git-gui/lib
exedir_SQ = $(subst ','\'',$(exedir))

$(patsubst %.sh,%,$(SCRIPT_SH)) : % : %.sh
	$(QUIET_GEN)rm -f $@ $@+ && \
	if test '$(exedir_SQ)' = '$(libdir_SQ)'; then \
		GITGUI_RELATIVE=1; \
	fi && \
	sed -e '1s|#!.*/sh|#!$(SHELL_PATH_SQ)|' \
		-e 's|^exec wish "$$0"|exec $(subst |,'\|',$(TCLTK_PATH_SQ)) "$$0"|' \
		-e 's/@@GITGUI_VERSION@@/$(GITGUI_VERSION)/g' \
		-e 's|@@GITGUI_RELATIVE@@|'$$GITGUI_RELATIVE'|' \
		-e $$GITGUI_RELATIVE's|@@GITGUI_LIBDIR@@|$(libdir_SQ)|' \
		$@.sh >$@+ && \
	chmod +x $@+ && \
	mv $@+ $@

$(GITGUI_BUILT_INS): git-gui
	$(QUIET_BUILT_IN)rm -f $@ && ln git-gui $@

lib/tclIndex: $(ALL_LIBFILES)
	$(QUIET_INDEX)if echo \
	  $(foreach p,$(PRELOAD_FILES),source $p\;) \
	  auto_mkindex lib '*.tcl' \
	| $(TCL_PATH) $(QUIET_2DEVNULL); then : ok; \
	else \
	 echo 1>&2 "    * $(TCL_PATH) failed; using unoptimized loading"; \
	 rm -f $@ ; \
	 echo '# Autogenerated by git-gui Makefile' >$@ && \
	 echo >>$@ && \
	 $(foreach p,$(PRELOAD_FILES) $(ALL_LIBFILES),echo '$(subst lib/,,$p)' >>$@ &&) \
	 echo >>$@ ; \
	fi

# These can record GITGUI_VERSION
$(patsubst %.sh,%,$(SCRIPT_SH)): GIT-VERSION-FILE GIT-GUI-VARS
lib/tclIndex: GIT-GUI-VARS

TRACK_VARS = \
	$(subst ','\'',SHELL_PATH='$(SHELL_PATH_SQ)') \
	$(subst ','\'',TCL_PATH='$(TCL_PATH_SQ)') \
	$(subst ','\'',TCLTK_PATH='$(TCLTK_PATH_SQ)') \
	$(subst ','\'',gitexecdir='$(gitexecdir_SQ)') \
	$(subst ','\'',libdir='$(libdir_SQ)') \
#end TRACK_VARS

GIT-GUI-VARS: .FORCE-GIT-GUI-VARS
	@VARS='$(TRACK_VARS)'; \
	if test x"$$VARS" != x"`cat $@ 2>/dev/null`" ; then \
		echo 1>&2 "    * new locations or Tcl/Tk interpreter"; \
		echo 1>$@ "$$VARS"; \
	fi

all:: $(ALL_PROGRAMS) lib/tclIndex

install: all
	$(INSTALL) -d -m755 '$(DESTDIR_SQ)$(gitexecdir_SQ)'
	$(INSTALL) git-gui '$(DESTDIR_SQ)$(gitexecdir_SQ)'
	$(foreach p,$(GITGUI_BUILT_INS), rm -f '$(DESTDIR_SQ)$(gitexecdir_SQ)/$p' && ln '$(DESTDIR_SQ)$(gitexecdir_SQ)/git-gui' '$(DESTDIR_SQ)$(gitexecdir_SQ)/$p' ;)
	$(INSTALL) -d -m755 '$(DESTDIR_SQ)$(libdir_SQ)'
	$(INSTALL) -m644 lib/tclIndex '$(DESTDIR_SQ)$(libdir_SQ)'
	$(foreach p,$(ALL_LIBFILES), $(INSTALL) -m644 $p '$(DESTDIR_SQ)$(libdir_SQ)' ;)

dist-version:
	@mkdir -p $(TARDIR)
	@echo $(GITGUI_VERSION) > $(TARDIR)/version

clean::
	rm -f $(ALL_PROGRAMS) lib/tclIndex
	rm -f GIT-VERSION-FILE GIT-GUI-VARS

.PHONY: all install dist-version clean
.PHONY: .FORCE-GIT-VERSION-FILE
.PHONY: .FORCE-GIT-GUI-VARS
