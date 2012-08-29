#!/bin/bash

debug=tomcat

export HOME=/home/gentoo

## setup ssh-agent
#eval `ssh-agent`
#. /home/aliz/.keychain/`uname -n`-sh

## remove false positives

false_ebuilds=(
	[0]=games-server-halflife-statsme-2.7.1
	[1]=games-emulation-snes9x-1.4.2-r1
)

false_md5sum=(
	[0]=97940610128731bce287407ec858c473
	[1]=1951a2a2ded803d369d70c63ce060938
)

## initial setup

## variables
# portage dir, without trailing /
portage_dir=/usr/portage

ARCHES="alpha amd64 arm hppa ia64 m68k mips ppc ppc64 ppc-macos ppc-od s390 sh sparc x86 x86-fbsd x86-od"
total_ebuilds=0

tmp=$( mktemp -d -p ~/tmp )
seconds=$( date +%s )

## inherit functions
source /sbin/functions.sh
## functions

check_false_positive() {
  local num

  num=0

  for a in ${false_ebuilds[@]}; do
    if [ "${a}" == "${category}-${package}-${version}" ]; then
      if [ "$( md5sum $ebuild | awk '{print $1}' )" == "${false_md5sum[${num}]}" ]; then
        einfo "False positive detected: $category/$package"
        return 1
      fi
    fi
    let num=$num+1
  done
  return 0
}

expand_variable() {
  local data

  data="$( sed -n "s:^$1=\".*\":&:p" $ebuild | head -n 1 )"
  if [ -z "$data" ]; then
    data="$( sed -n "/^$1=\"/,/\"$/p" $ebuild )"
  fi
  if [ -z "$data" ]; then
    data="$( sed -n "s:^$1=.*:&:p" $ebuild | head -n 1 )"
  fi

  echo $data | sed -e "s:^$1=::g" -e "s:\([^#]\)#.*:\1:g" -e 's:"::g'
}

do_db() {
  echo "$*;" | mysql -u gentoo -pxxx gentoo
#  echo "$*;" | psql  -h sputnik.tamperd.net -U wwwdata gentoo >/dev/null
#echo "$*;"
}

db_commit() {
  if [ -e $tmp/insert ]; then
    cat $tmp/insert | ssh -C aliz@sputnik.tamperd.net "psql -U wwwdata gentoo >/dev/null"
    einfo "Commited $( wc -l $tmp/insert | awk '{print $1}' ) lines to database $( test -z $old_category || echo "($old_category)" ) - $SECONDS"
    rm -f $tmp/insert
  fi
}

esyslog() {
  return 0
}

check_mask() {
  local DEBUG
  local KEYWORDS
  local SLOT
  local arch
  local keyword

  # create working dir for ${category}/${package}
  mkdir -p ${tmp}/${category}/${package}

  KEYWORDS="$( expand_variable KEYWORDS )"
  SLOT="$( expand_variable SLOT )"

  for arch in $ARCHES; do
    for keyword in $KEYWORDS; do
      if [ "$keyword" == "${arch}" -o "$keyword" == "~${arch}" ]; then
        # ebuild has ${arch} keyword and it's not -${arch}
        if [ "$keyword" == "${arch}" ]; then
          # found stable ${arch} keyword
          if [ ! -e ${tmp}/${category}_${package}_${arch}_${SLOT} ]; then
            # found first stable
            touch ${tmp}/${category}_${package}_${arch}_${SLOT}
            touch ${tmp}/${category}/${package}/${package}-${version}
          fi
        else
          if [ ! -e ${tmp}/${category}_${package}_${arch}_${SLOT} ]; then
            touch ${tmp}/_include_${category}_${package}_${version}_${arch}
            touch ${tmp}/_include_${category}_${package}_${version}
            touch ${tmp}/${category}/${package}/${package}-${version}
          fi
        fi
        break
      fi
    done
  done
}

get_keywords() {
  local DEBUG
  local KEYWORDS
  local arch
  local keyword

  # create working dir for $category/$package
  mkdir -p $tmp/$category/${package}

  KEYWORDS="$( expand_variable KEYWORDS )"

  for arch in $ARCHES; do
    for keyword in $KEYWORDS; do
      if [ "$keyword" == "~${arch}" -o "$keyword" == "${arch}" ]; then
        touch $tmp/_keyword_${category}_${package}_${arch}
#       touch ${tmp}/${category}/${package}/${package}-${version}
      fi
    done
  done
}

get_missing() {
  local DEBUG
  local KEYWORDS
  local arch

  # create working dir for $category/$package
  mkdir -p $tmp/$category/${package}

  KEYWORDS="$( expand_variable KEYWORDS )"

  for arch in $ARCHES; do
    if [ -e $tmp/_keyword_${category}_${package}_${arch} ]; then
      if [ ! "$( echo "${KEYWORDS}" | egrep -e "${arch}" -e '-\*' )" ]; then
        touch $tmp/_missing_${category}_${package}_${version}_${arch}
        touch $tmp/_missing_${category}_${package}_${version}
      else
        rm -f $tmp/_keyword_${category}_${package}_${arch}
      fi
    fi
  done
}

get_herd() {
  local a
  local b
  local herd
  local maintainer

  if [ -f $metadata ]; then
    herd=$( egrep "<herd>(.*)</herd>" $metadata | sed -e "s:<herd>\(.*\)</herd>:\1:g" -e "s:[[:space:]]::g" )
    if [ ! -z "$herd" ]; then
      for a in $herd; do
        if [ "$herd" == "no-herd" ]; then
          for b in $( egrep "<email>(.*)</email>" $metadata | sed -e "s:.*<email>\(.*\)</email>.*:\1:g" -e "s:[[:space:]]::g" ); do
            herd_db="$herd_db $b"
          done
        else
          herd_db="$herd_db $a"
        fi
      done
    else
      for b in $( egrep "<email>(.*)</email>" $metadata | sed -e "s:.*<email>\(.*\)</email>.*:\1:g" -e "s:[[:space:]]::g" ); do
        herd_db="$herd_db $b"
      done
    fi
    for a in $( egrep "<maintainer><email>(.*)</email></maintainer>" $metadata | sed -e "s:.*<maintainer><email>\(.*\)</email></maintainer>.*:\1:g" -e "s:[[:space:]]::g" ); do
      herd_db="$herd_db $a"
    done
  fi

  echo $herd_db | sed "s:@gentoo.org:@g.o:g" | tr " " "\n" | sort -u | tr "\n" " "
}

db_insert() {
  local herd
  local keyword
  local urls
  local checks
  local DEBUG
  local inherit_loop
  local masked_arches

  export DEBUG=${ebuild}

  herd="$( get_herd )"

  if [ -e $tmp/_check_${category}_${package}_${version} ]; then
OLDIFS=$IFS
IFS="
"
    for a in $( cat $tmp/_check_${category}_${package}_${version} | sort -u ); do
      IFS=$OLDIFS
      case $a in
        mirror://*)
          urls="$urls ${a/mirror:\/\//}<br />"
        ;;
        fPIC)
          checks="$checks <a href=\"#\">fPIC<span><strong>fPIC</strong><br /><br />ebuild forces -fPIC to CFLAGS.</span></a>"
        ;;
        HOMEPAGE)
          checks="$checks <a href=\"#\">HOMEPAGE<span><strong>HOMEPAGE</strong><br /><br />ebuild has \${HOMEPAGE} in SRC_URI.</span></a>"
        ;;
        PN)
          checks="$checks <a href=\"#\">PN<span><strong>PN</strong><br /><br />SRC_URI contains \${PN}.</span></a>"
        ;;
        sed-i)
          checks="$checks <a href=\"#\">sed -i<span><strong>sed -i</strong><br /><br />Found sed in ebuild that maybe could be replaced by sed -i.</span></a>"
        ;;
        epatch)
          checks="$checks <a href=\"#\">epatch<span><strong>epatch</strong><br /><br />Found patch in ebuild that maybe could be replaced by epatch.</span></a>"
        ;;
        eutils)
          checks="$checks <a href=\"#\">!eutils<span><strong>!eutils</strong><br /><br />Ebuild uses functions from eclass eutils but doesn\'t inherit it.</span></a>"
        ;;
        flagomatic)
          checks="$checks <a href=\"#\">!flag-o-matic<span><strong>!flag-o-matic</strong><br /><br />Ebuild uses functions from eclass flag-o-matic but doesn\'t inherit it.</span></a>"
        ;;
        S)
          checks="$checks <a href=\"#\">S=<span><strong>S=</strong><br /><br />Ebuild sets \$S to \${WORKDIR}/\${P} which is unneccesary.</span></a>"
        ;;
        redefine)
          checks="$checks <a href=\"#\">redefine<span><strong>redefine</strong><br /><br />Ebuild redefines P, PV, PN or PF.</span></a>"
        ;;
        install_copying_dodoc)
          checks="$checks <a href=\"#\">install_copying_dodoc<span><strong>install_copying_dodoc</strong><br /><br />Ebuild install INSTALL and/or COPYING into doc.</span></a>"
        ;;
        iuse_missing)
          checks="$checks <a href=\"#\">!IUSE<span><strong>!IUSE</strong><br /><br />Ebuild doesn\'t have IUSE.</span></a>"
        ;;
        use_unsync*)
          checks="$checks <a href=\"#\">?USE<span><strong>?USE</strong><br /><br />The following use variables are unsynched:<br />${a/use_unsync/}</span></a>"
        ;;
        autoconf*)
          checks="$checks <a href=\"#\">autoconf<span><strong>autoconf</strong><br /><br />Ebuild uses depreceated WANT_AUTOCONF_?_? syntax.</span></a>"
        ;;
        automake*)
          checks="$checks <a href=\"#\">automake<span><strong>automake</strong><br /><br />Ebuild uses depreceated WANT_AUTOMAKE_?_? syntax.</span></a>"
        ;;
        has_pic*)
          checks="$checks <a href=\"#\">autoconf<span><strong>has_pic</strong><br /><br />Ebuild uses is-flag -fPIC when it should use has_pic.</span></a>"
        ;;
	rdepend_depend)
          checks="$checks <a href=\"#\">RDEPEND_DEPEND<span><strong>RDEPEND_DEPEND</strong><br /><br />Ebuild has \$RDEPEND=\$DEPEND.</span></a>"
        ;;
	rdepend_rdepend)
          checks="$checks <a href=\"#\">RDEPEND_RDEPEND<span><strong>RDEPEND_RDEPEND</strong><br /><br />Ebuild has \$RDEPEND=\$RDEPEND.</span></a>"
        ;;
	depend_depend)
          checks="$checks <a href=\"#\">DEPEND_DEPEND<span><strong>DEPEND_DEPEND</strong><br /><br />Ebuild has \$DEPEND=\$DEPEND.</span></a>"
        ;;
        arch_iuse)
          checks="$checks <a href=\"#\">arch_iuse<span><strong>arch_iuse</strong><br /><br />Ebuild has arch keyword in IUSE.</span></a>"
        ;;
        makeopts)
          checks="$checks <a href=\"#\">MAKEOPTS<span><strong>MAKEOPTS</strong><br /><br />Ebuild overrides MAKEOPTS.</span></a>"
        ;;
        use_invocation)
          checks="$checks <a href=\"#\">use_invocation<span><strong>use_invocation</strong><br /><br />Wrong use invocation.</span></a>"
        ;;
        rdepend_autoconf)
          checks="$checks <a href=\"#\">rdepend_autoconf<span><strong>rdepend_autoconf/automake</strong><br /><br />autoconf specified in RDEPEND.</span></a>"
        ;;
        rdepend_automake)
          checks="$checks <a href=\"#\">rdepend_automake<span><strong>rdepend_automake</strong><br /><br />automake specified in RDEPEND.</span></a>"
        ;;
        rdepend_libtool)
          checks="$checks <a href=\"#\">rdepend_libtool<span><strong>rdepend_libtool</strong><br /><br />libtool specified in RDEPEND.</span></a>"
        ;;
        not_in_changelog)
          checks="$checks <a href=\"#\">not_in_changelog<span><strong>not_in_changelog</strong><br /><br />Version not specified in changelog.</span></a>"
        ;;
        changelog_date_error)
          checks="$checks <a href=\"#\">changelog_date_error<span><strong>changelog_date_error</strong><br /><br />Date format specified in changelog is wrong.</span></a>"
        ;;
        *)
          einfo "Unkown check: $a"
        ;;
    esac
  done
    if [ ! -z "$urls" ]; then
      checks="$checks <a href=\"#\">mirror://<span><strong>mirror://</strong><br /><br />The following urls with hosts in thirdpartymirrors was found:<br />$urls</span></a>"
    fi
  fi

  for arch in $ARCHES; do
    if [ -e $tmp/_include_${category}_${package}_${version}_${arch} ]; then
      do_db "insert into ${arch/-/} (package,mask) values('${package}-${version}','~${arch}')"
      if [ -z "${masked_arches}" ]; then
        masked_arches="~${arch}"
      else
        masked_arches="${masked_arches} ~${arch}"
      fi
    elif [ -e $tmp/_missing_${category}_${package}_${version}_${arch} ] && [ -e "$tmp/_include_${category}_${package}_${version}" ]; then
      do_db "insert into ${arch/-/} (package,mask) values('${package}-${version}','?${arch}')"
    fi
  done

  do_db "insert into ebuilds (category,package,herd,days,checks,masked_arches) values('$category','$package-${version}','$herd','$ebuild_age','$checks','${masked_arches}')"
}

check_inherit() {
  local DEBUG
  local inherit
  local a

  export DEBUG=${ebuild}

  inherit=$( sed -n "s:^inherit \(.*\)$:\1:p" $ebuild )
  
  for a in $inherit; do     
    touch $tmp/_inherit_${a}_${category}_${package}_${version}
  done
}

check_DEPEND() {
  local a

  for a in "$( expand_variable RDEPEND )"; do
    case $a in
      \${DEPEND} | \$DEPEND)
        echo "rdepend_depend" >>$tmp/_check_${category}_${package}_${version}
      ;;
      \${RDEPEND} | \$RDEPEND)
        echo "rdepend_rdepend" >>$tmp/_check_${category}_${package}_${version}
      ;;
      *automake*)
        echo "rdepend_automake" >>$tmp/_check_${category}_${package}_${version}
      ;;
      *autoconf*)
        echo "rdepend_autoconf" >>$tmp/_check_${category}_${package}_${version}
      ;;
      *libtool*)
        echo "rdepend_libtool" >>$tmp/_check_${category}_${package}_${version}
      ;;
    esac
  done

  for a in "$( expand_variable DEPEND )"; do
    case $a in
      \${DEPEND} | \$DEPEND)
        echo "depend_depend" >>$tmp/_check_${category}_${package}_${version}
      ;;
    esac
  done
}

check_IUSE() {
  local use
  local element
  local IUSE
  local flag
  local use_ebuild
  local iuse_ebuild
  local count
  local DEBUG
  local use_var
  local a
  local b

  export DEBUG=${ebuild}

  if [ ! "$( egrep -e "^IUSE=\"" $ebuild )" ]; then
    echo "iuse_missing" >>$tmp/_check_${category}_${package}_${version}
  else
    for a in SRC_URI DEPEND RDEPEND PDEPEND; do
      use_var="$use_var $( expand_variable ${a} )"
    done

    for a in $use_var; do
      case ${a} in
        *[A-Za-z0-9]*\? | *\![A-Za-z0-9]*\? )
          use_ebuild="$use_ebuild $a"
        ;;
      esac
    done


    IUSE="$( expand_variable IUSE | sed -e 's:(::' -e 's:)::' -e 's:[a-z0-9]*?::' -e 's:`.*`::g' -e 's:\\::g' -e 's:\$:\\$:g' )"

    for a in $( cat ${portage_dir}/profiles/arch.list ); do
      for b in ${IUSE}; do
        if [ "${a}" == "${b}" ]; then
          echo "arch_iuse" >>$tmp/_check_${category}_${package}_${version}
        fi
      done
    done

#    use=( null $( cat $ebuild \
#		| egrep -v -e "^[A-Z_]+=" \
#		| sed -r 's:(die|ebegin|echo|einfo|ewarn|eerror) ".*"::g' \
#		| sed -e 's:EPATCH_SINGLE_MSG=".*"::g' \
#			-e "s:\(.\)\(use\) \([-a-zA-Z0-9]*\): \1\2 \3:g" \
#			-e "s:\(||\)\(.*\):\1 \2:g" \
#			-e "s:\(&&\)\(.*\):\1 \2:g" \
#			-e "s:\([^#]\)#.*:\1:g" \
#			-e "s:^\(.*\)\#.*:\1:g" ) )
#   count=0
#
#   for element in ${use[@]}; do
#      case $element in
#        *use_with | *use_enable | *seduse )
#          use_ebuild="$use_ebuild ${use[$count+1]}"
#        ;;
#        \`use)
#            use_ebuild="$use_ebuild ${use[$count+1]}"
#        ;;
#        *use)
#          if [ "${use[$count-1]}" == "-n" ] || [ "${use[$count-1]}" == "!" ] || [ "${use[$count-1]}" == "-a" ] || [ "${use[$count-1]}" == "-o" ] || [ "${use[$count-1]}" == "-z" ]; then
#            use_ebuild="$use_ebuild ${use[$count+1]}"
#          elif [ "${use[$count-1]}" == "[" ] || [ "${use[$count+2]}" == "]" ]; then
#            use_ebuild="$use_ebuild ${use[$count+1]}"
#          elif [ "${use[$count+3]}" == "&&" ] || [ "${use[$count+3]}" == "||" ]; then
#            use_ebuild="$use_ebuild ${use[$count+1]}"
#          elif [ "${use[$count+2]}" == "&&" ] || [ "${use[$count+2]}" == "||" ]; then
#            use_ebuild="$use_ebuild ${use[$count+1]}"
#          elif [ "${use[$count-1]}" == "&&" ] || [ "${use[$count-1]}" == "||" ]; then
#            use_ebuild="$use_ebuild ${use[$count+1]}"
#          elif [ "${use[$count+2]}" == ">/dev/null" ]; then
#            use_ebuild="$use_ebuild ${use[$count+1]}"
#          elif [ "${use[$count+2]}" == ">" ] && [ "${use[$count+3]}" == "/dev/null" ]; then
#            use_ebuild="$use_ebuild ${use[$count+1]}"
#          elif [ "${use[$count+2]}" == "&>" ] && [ "${use[$count+3]}" == "/dev/null" ]; then
#            use_ebuild="$use_ebuild ${use[$count+1]}"
#          elif [ "${use[$count+2]}" == "\`\"" ]; then
#            use_ebuild="$use_ebuild ${use[$count+1]}"
#          elif [ "${use[$count+2]}" == ")" ]; then
#            use_ebuild="$use_ebuild ${use[$count+1]}"
#          elif [ "${use[$count+2]}" == "then" ]; then
#            use_ebuild="$use_ebuild ${use[$count+1]}"
#          elif [ "${use[$count+2]}" == "\\" ]; then
#            use_ebuild="$use_ebuild ${use[$count+1]}"
#          elif [ "${use[$count+3]}" == "then" ]; then
#            use_ebuild="$use_ebuild ${use[$count+1]}"
#          elif [ "${use[$count-1]}" == "if" ] || [ "${use[$count-1]}" == "\"\$" ]; then
#            use_ebuild="$use_ebuild ${use[$count+1]}"
#          elif [ "${use[$count-1]}" == "elif" ]; then
#            use_ebuild="$use_ebuild ${use[$count+1]}"
#          else
#            echo "bad: ${use[$count-1]} $element ${use[$count+1]} ${use[$count+2]} ($package-$version)"
#          fi
#        ;;
#      esac
#      let count=$count+1
#    done
#
#    if [ -z "$IUSE" -a ! -z "$use_ebuild" ]; then
#      check_false_positive && (
#        use_ebuild=$( echo $use_ebuild | tr " " "\n" | sed -e 's:SRC_URI="::g' -e 's:RDEPEND="::g' -e 's:DEPEND="::g' -e 's:PDEPEND="::g' -e "s:\!::" -e "s:\?::" -e "s:\([-A-Za-z0-9_]*\).*:\1:" | sort -u | grep -v -f ${portage_dir}/profiles/arch.list | tr "\n" " " )
#        test -z "$use_ebuild" || echo "use_unsync ${use_ebuild}" >>$tmp/_check_${category}_${package}_${version}
#      )
#    elif [ ! -z "$IUSE" -a -z "$use_ebuild" ]; then
#        echo "use_unsync ${IUSE}" >>$tmp/_check_${category}_${package}_${version}
#    elif [ ! -z "$IUSE" -a ! -z "$use_ebuild" ]; then
#      use_ebuild=$( echo $use_ebuild | tr " " "\n" | sed -e 's:SRC_URI="::g' -e 's:RDEPEND="::g' -e 's:DEPEND="::g' -e 's:PDEPEND="::g' -e "s:\!::" -e "s:\?::" -e "s:\([-A-Za-z0-9_]*\).*:\1:" | sort -u | grep -v -f ${portage_dir}/profiles/arch.list | tr "\n" " " )
#      iuse_ebuild=$( echo $IUSE | tr " " "\n" | sort -u | tr "\n" " " )
#
#      use_ebuild_test=$( echo $use_ebuild | sed "s: ::g" )
#      iuse_ebuild_test=$( echo $iuse_ebuild | sed "s: ::g" )
#
#      if [ "${use_ebuild_test}" != "${iuse_ebuild_test}" ]; then
#        check_false_positive && (
#          echo "use_unsync $( echo ${use_ebuild} ${iuse_ebuild} | tr " " "\n" | sort | uniq -u | tr "\n" " " )" >>$tmp/_check_${category}_${package}_${version}
#        )
#      fi
#    fi
  fi
}

check_SRC_URI() {
  local a
  local host
  local url
  local PN
  local SRC_URI
  local HOMEPAGE
  local DEBUG

  HOMEPAGE=HOMEPAGE
  PN=$$

  export DEBUG=${ebuild}

  SRC_URI="$( expand_variable SRC_URI | sed -e 's:(::' -e 's:)::' -e 's:[a-z0-9]*?::' -e 's:`.*`::g' -e 's:\\::g' -e 's:\$:\\$:g' )"

  for a in ${SRC_URI}; do
    case $a in
      *\${HOMEPAGE}* | *\$HOMEPAGE*)
        echo "HOMEPAGE" >> $tmp/_check_${category}_${package}_${version}
      ;;
      */\${PN}/* | */\$PN/*)
        echo "PN" >>$tmp/_check_${category}_${package}_${version}
      ;;
      mirror://*)
        continue
      ;;
    esac

    url=$( echo $a | sed "s:^\(.*\)/.*$:\1:g" | sed "s:http\://\(.*\)\.dl\.sf\.net:http\://\1\.dl\.sourceforge\.net:g" )
    host=$( echo $url | sed -r 's:(http|ftp)(\://)([a-zA-Z0-9\.\-]*)/.*:\1\2\3:g' )

    if [ -z "$( sed "s,$host,$$,g" $tmp/mirrors | grep $$ )" ]; then
      continue
    fi

    if [ -z $url ]; then
      eerror "${category}/${package}-${version}: url is null"
      continue
    fi

    if [ $( echo $url | fgrep ${thirdpartymirrors} ) ]; then 
      echo "mirror://${url}" >>$tmp/_check_${category}_${package}_${version}
    fi
  done

}

check_other() {
  if [ "$( sed "s:\(.*\)\(#.*\):\1:g" $ebuild | egrep -e "(filter|append|replace|is|strip)-flags" -e "get-flag" )" -a ! -e $tmp/_inherit_flag-o-matic_${category}_${package}_${version} ]; then
    echo "flagomatic" >> $tmp/_check_${category}_${package}_${version}
  fi

 if [ "$( sed "s:\(.*\)\(#.*\):\1:g" $ebuild | egrep -e "(draw-line|epatch|enewuser|enewgroup|edos2unix)" )" -a ! -e $tmp/_inherit_eutils_${category}_${package}_${version} ]; then
    echo "eutils" >> $tmp/_check_${category}_${package}_${version}
 fi

 if [ "$( sed "s:\(.*\)\(#.*\):\1:g" $ebuild | grep "dodoc" | grep -e " INSTALL" -e " COPYING" )" ]; then
    echo "install_copying_dodoc" >> $tmp/_check_${category}_${package}_${version} 
 fi

#       if [ "$( egrep "sed(.*)[[:space:]](\"|\'|\\|[a-z]|<)" $ebuild | grep -v -- "-i" | egrep -v -e dosed -e "^#" )" ]; then
#        echo "sed-i" >>$tmp/_check_${category}_${package}_${version}
#       fi

        if [ "$( egrep -e '^S=[\"]?\$[\{]?WORKDIR[\}]?/\$[\{]?P[\}]?[\"]?$' $ebuild )" ]; then
         echo "S" >>$tmp/_check_${category}_${package}_${version}
        fi

        if [ "$( egrep -e '^[(P|PV|PN|PF)]=' $ebuild )" ]; then
          echo "redefine" >>$tmp/_check_${category}_${package}_${version}
        fi

        if [ "$( sed -r 's:(die|ebegin|echo|einfo|ewarn|eerror) ".*"::g' ${ebuild} | sed -e "s:\([^#]\)#.*:\1:g" -e "s:^\(.*\)\#.*:\1:g" | egrep "patch([[:space:]]-p[0-9])? <" )" ]; then
          echo "epatch" >>$tmp/_check_${category}_${package}_${version}
        fi

        if [ "$( sed -r 's:(die|ebegin|echo|einfo|ewarn|eerror) ".*"::g' ${ebuild} | sed -e "s:\([^#]\)#.*:\1:g" -e "s:^\(.*\)\#.*:\1:g" | egrep -i -e "append-flags -fpic" -e "CFLAGS=[\"]?${CFLAGS} -fPIC[\"]?" )" ]; then
          echo "fPIC" >> $tmp/_check_${category}_${package}_${version}
        fi

        if [ "$( sed -r 's:(die|ebegin|echo|einfo|ewarn|eerror) ".*"::g' ${ebuild} | sed -e "s:\([^#]\)#.*:\1:g" -e "s:^\(.*\)\#.*:\1:g" | egrep "WANT_AUTOCONF_[0-9]_[0-9]=" )" ]; then
          echo "autoconf" >> $tmp/_check_${category}_${package}_${version}
        fi

        if [ "$( sed -r 's:(die|ebegin|echo|einfo|ewarn|eerror) ".*"::g' ${ebuild} | sed -e "s:\([^#]\)#.*:\1:g" -e "s:^\(.*\)\#.*:\1:g" | egrep "WANT_AUTOMAKE_[0-9]_[0-9]=" )" ]; then
          echo "automake" >> $tmp/_check_${category}_${package}_${version}
        fi

        if [ "$( sed -r 's:(die|ebegin|echo|einfo|ewarn|eerror) ".*"::g' ${ebuild} | sed -e "s:\([^#]\)#.*:\1:g" -e "s:^\(.*\)\#.*:\1:g" | egrep -i "is-flag -fPIC" )" ]; then
          echo "has_pic" >> $tmp/_check_${category}_${package}_${version}
        fi

        if [ "$( sed -r 's:(die|ebegin|echo|einfo|ewarn|eerror) ".*"::g' ${ebuild} | sed -e "s:\([^#]\)#.*:\1:g" -e "s:^\(.*\)\#.*:\1:g" | egrep "MAKEOPTS=" )" ]; then
          echo "makeopts" >> $tmp/_check_${category}_${package}_${version}
        fi

        if [ "$( sed -r 's:(die|ebegin|echo|einfo|ewarn|eerror) ".*"::g' ${ebuild} | sed -e "s:\([^#]\)#.*:\1:g" -e "s:^\(.*\)\#.*:\1:g" | egrep "\[.*use.*\]" $ebuild )" ]; then
          echo "use_invocation" >>$tmp/_check_${category}_${package}_${version}
        fi
}

####################################################################################################
##
## let the madness begin!
##

# turn on debugging if requested
if [ "$1" == "-x" ]; then
  set -x
  shift
fi
# flush the database
do_db "delete from ebuilds"
do_db "delete from lastupdated"
for a in ${ARCHES}; do
  do_db "delete from ${a/-/}"
done
do_db "insert into lastupdated values('currently running...')"
db_commit

## sync tree
#cd ${portage_dir}
#cvs -Q up -dP

sudo emerge --sync -q --nospinner --color=n

# setup thirdpartymirrors
ebegin "Generating mirror list"
  OLDIFS=$IFS
  IFS="
"
  for mirrors in $( cat $portage_dir/profiles/thirdpartymirrors ); do
    IFS=$OLDIFS
    i=0
    for b in $mirrors; do
      if [ "$i" == "0" ]; then
        i=1
        continue
      fi
      thirdpartymirrors="$thirdpartymirrors -e $b"
      echo $b >>$tmp/mirrors
    done  
  done
eend $?

# begin

if [ -z $1 ]; then
  depth="2"
else
  depth="1"
fi

for package_raw in $( find $portage_dir/$1 -maxdepth $depth -mindepth $depth -type d ); do
  old_category=$category

  unset category 
  unset package 
  unset changelog 
  unset metadata

  category=$( echo $package_raw | sed "s:$portage_dir/::" | awk -F '/' '{print $1}' )		# app-arch
  package=$( echo $package_raw | sed "s:$portage_dir/::" | awk -F '/' '{print $2}' )		# arj
  changelog=$portage_dir/$category/$package/ChangeLog						# full path to ChangeLog
  metadata=$portage_dir/$category/$package/metadata.xml						# full path to metadata.xml

#if [ "$package" == "$debug" ]; then
#  set -x
#else
#  set +x
#fi


  if [ "$old_category" != "$category" ]; then
    db_commit
  fi

  if [ "$package" == "CVS" ] || [ "$category" == "profiles" ] || [ "$category" == "eclass" ] || [ "$category" == "packages" ] || [ "$category" == "distfiles" ]; then
    continue
  fi

  if [ ! -s $changelog ]; then
    eerror "$category/$package: changelog does not exist or is zero bytes"
  else
    category_in_changelog=$( head -n 1 $changelog | awk '{print $4}' )
    if [ "$category_in_changelog" != "$category/$package" ]; then
      ewarn "$category/$package: invalid section"
    fi
  fi

  if [ "$( echo $package | egrep -e "-cvs" )" ]; then
    continue
  fi

  unset versions_raw
  # list of versions
  versions_raw=$( find $portage_dir/$category/$package -name '*.ebuild' -type f -printf "%f\n" \
		| sed -e "s:.ebuild$::g" -e "s:^${package}-::g" \
		| tr "\n" " " )
#		| grep -v -e "_alpha[0-9]" -e "_beta[0-9]" -e "_pre[0-9]" -e "_rc[0-9]" \

  unset version
  # populate missing keywords
  for version in $( echo $versions_raw | ~/bin/sort_reverse.pl ); do
    unset ebuild

    ebuild=${portage_dir}/${category}/${package}/${package}-${version}.ebuild				# full path to .ebuild

    get_keywords
  done


  unset version
  # create list of ebuilds that we want to check.
  for version in $( echo $versions_raw | ~/bin/sort.pl ); do
    unset ebuild

    ebuild=${portage_dir}/${category}/${package}/${package}-${version}.ebuild				# full path to .ebuild

    check_mask
    get_missing
  done

  if [ ! -d $tmp/$category/$package ]; then
    continue
  fi

  unset ebuild_raw
  for ebuild_raw in $( ls -1 $tmp/$category/$package ); do
    unset ebuild
    unset version

    ebuild=$portage_dir/$category/$package/${ebuild_raw}.ebuild
    version=${ebuild_raw/${package}-/}

    if [ "$( egrep "^\*$( echo "${package}-${version}" | sed "s:+:(.):g" )[[:space:]]\(" $changelog )" ]; then
      unset ebuild_date
      ebuild_date=$( egrep "^\*${package}-${version}[[:space:]]\(" $changelog | awk -F'(' '{print $2}' | sed -e "s:(::g" -e "s:)::g" | tail -n 1 )
       if [ "$( date +%s --date="$ebuild_date" 2>/dev/null )" ]; then
         difference=$[$seconds-$( date +%s --date="$ebuild_date" )]
         ebuild_age=$[$difference/86400]

         check_SRC_URI
         check_inherit
         check_IUSE
         check_DEPEND
         check_other

        if [ $difference -ge 2592000 -a -e $tmp/_include_${category}_${package}_${version} ] || [ -e $tmp/_check_${category}_${package}_${version} ] || [ -e $tmp/_missing_${category}_${package}_${version} ]; then
          let total_ebuilds=$total_ebuilds+1
          db_insert
        fi 
      else
        ebuild_age=-1
        echo "changelog_date_error" >>$tmp/_check_${category}_${package}_${version}
        let total_ebuilds=$total_ebuilds+1
        db_insert
      fi
    elif [ $package == portage -o $package == linux-gazette -o $package == linux-gazette-base -o $package == linux-gazette-all -o $package == phrack -o $package == ufed ]; then
      do=nothing
    else
      ebuild_age=-1
      echo "not_in_changelog" >>$tmp/_check_${category}_${package}_${version}
      let total_ebuilds=$total_ebuilds+1
      db_insert
#      eerror "$category/$package: ${package}-${version} does not exist in changelog"
    fi
  done
done

do_db "delete from lastupdated"
do_db "insert into lastupdated values('$( date -u )')"
db_commit

mail=$tmp/mail
if [ ! -e ~/history/gentoo_maint_$( date +%V )_$( date +%Y ) ]; then
  touch ~/history/gentoo_maint_$( date +%V )_$( date +%Y )
  to="gentoo-dev@gentoo.org"
fi

if [ "$1" == "" ]; then
  subject=""
else
  subject="($1)"
fi

echo "From: Daniel Ahlberg <aliz@tamperd.net>" > $mail
echo "To: $to,aliz@tamperd.net" >> $mail
echo "Subject: aging ebuilds with unstable keywords $subject" >> $mail
echo -e "Hi,\n\nThis is an automatically created email message." >> $mail
echo -e "http://gentoo.tamperd.net/stable has just been updated with $total_ebuilds ebuilds." >> $mail
echo -e "" >> $mail
echo -e "The page shows results from a number of tests that are run against the ebuilds. The tests are:" >>$mail
echo -e "* if a version has been masked for 30 days or more." >>$mail
echo -e "* if an arch was in KEYWORDS in an older ebuild, but not in the newer ones." >>$mail
echo -e "* if SRC_URI contains hosts specified in thirdpartymirrors." >>$mail
echo -e "* if ebuild uses patch instead of epatch." >>$mail  
echo -e "* if ebuild sets S to \${WORKDIR}/\${P}." >>$mail
echo -e "* if ebuild redefines P, PV, PN or PF." >>$mail
#echo -e "* if ebuild doesn't use sed -i where it could do so." >>$mail
#echo -e "* If the use flags in the ebuild matches those in IUSE." >>$mail
#echo -e "* If ebuild sets IUSE." >>$mail
echo -e "* if ebuild doesn't inherit eutils when it uses functions from eutils." >>$mail
echo -e "* if ebuild doesn't inherit flag-o-matic when it uses functions from flag-o-matic." >>$mail
echo -e "* if ebuild has \$HOMEPAGE in SRC_URI (cosmetic)." >>$mail
echo -e "* if ebuild has \$PN in SRC_URI (cosmetic)." >>$mail
echo -e "* if ebuild forces -fPIC flag to CFLAGS." >>$mail
echo -e "* if ebuild has deprecated WANT_AUTO(CONF|MAKE)_?_?." >>$mail
echo -e "* if ebuild uses is-flag -fPIC, should be changed to has_fpic." >>$mail
echo -e "* if ebuild appends \$RDEPEND or \$DEPEND to \$RDEPEND or \$DEPEND to \$DEPEND." >>$mail
echo -e "* if ebuild has arch keyword(s) in iuse." >>$mail
echo -e "* if ebuild overrides MAKEOPTS." >>$mail
echo -e "* if ebuild has automake, autoconf or libtool in RDEPEND." >>$mail
echo -e "* if ebuild exists in ChangeLog." >>$mail
echo -e "* if ebuild installs COPYING and/or INSTALL into doc." >>$mail
echo -e "" >> $mail
#echo -e "TOP TEN:" >>$mail
#echo -e "========" >>$mail
#echo -e "" >>$mail
#mysql -u gentoo -pxxx -h tv -N -e "select category,package,days,masked_arches from ebuilds order by days desc limit 10" gentoo_stable >>$mail
#echo -e "" >>$mail
echo -e "The database is updated once a day and this email is sent once a week." >>$mail
echo -e "Questions and comments may be directed to aliz@tamperd.net." >> $mail
echo -e "\nScript has been running for $[SECONDS/60] minutes." >> $mail

cat $mail | /usr/sbin/sendmail -F"Daniel Ahlberg" -faliz@tamperd.net $to aliz@tamperd.net

cp $mail /tmp/mail

rm -rf $tmp $herd_dir
#eval `ssh-agent -k`
