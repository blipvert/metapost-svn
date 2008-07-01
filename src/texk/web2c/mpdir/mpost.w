% $Id$
%
% Copyright 2008 Taco Hoekwater.
%
% This program is free software: you can redistribute it and/or modify
% it under the terms of the GNU General Public License as published by
% the Free Software Foundation, either version 2 of the License, or
% (at your option) any later version.
%
% This program is distributed in the hope that it will be useful,
% but WITHOUT ANY WARRANTY; without even the implied warranty of
% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
% GNU General Public License for more details.
%
% You should have received a copy of the GNU General Public License
% along with this program.  If not, see <http://www.gnu.org/licenses/>.

\font\tenlogo=logo10 % font used for the METAFONT logo
\def\MP{{\tenlogo META}\-{\tenlogo POST}}

\def\title{MetaPost executable}
\def\[#1]{#1.}
\pdfoutput=1

@* \[1] Metapost executable.

Now that all of \MP\ is a library, a separate program is needed to 
have our customary command-line interface. 

@ First, here are the C includes. |avl.h| is needed because of an 
|avl_allocator| that is defined in |mplib.h|

@d true 1
@d false 0
 
@c
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <mplib.h>
#include <mpxout.h>
#ifdef WIN32
#include <process.h>
#endif
#include <kpathsea/kpathsea.h>
extern char *kpathsea_version_string;
static const char *mpost_tex_program = "";
static int debug = 0; /* debugging for makempx */

@ Allocating a bit of memory, with error detection:

@c
void  *xmalloc (size_t bytes) {
  void *w = malloc (bytes);
  if (w==NULL) {
    fprintf(stderr,"Out of memory!\n");
    exit(EXIT_FAILURE);
  }
  return w;
}
char *xstrdup(const char *s) {
  char *w; 
  if (s==NULL) return NULL;
  w = strdup(s);
  if (w==NULL) {
    fprintf(stderr,"Out of memory!\n");
    exit(EXIT_FAILURE);
  }
  return w;
}


@ @c
void mpost_run_editor (MP mp, char *fname, int fline) {
  char *temp, *command, *edit_value;
  char c;
  int sdone, ddone;
  sdone = ddone = 0;
  edit_value = kpse_var_value ("MPEDIT");
  if (edit_value == NULL)
    edit_value = getenv("EDITOR");
  if (edit_value == NULL) {
    fprintf (stderr,"call_edit: can't find a suitable MPEDIT or EDITOR variable\n");
    exit(mp_status(mp));    
  }
  command = (string) xmalloc (strlen (edit_value) + strlen(fname) + 11 + 3);
  temp = command;
  while ((c = *edit_value++) != 0) {
      if (c == '%')   {
        switch (c = *edit_value++) {
	    case 'd':
	      if (ddone) {
            fprintf (stderr,"call_edit: `%%d' appears twice in editor command\n");
            exit(EXIT_FAILURE);  
          }
          sprintf (temp, "%d", fline);
          while (*temp != '\0')
            temp++;
          ddone = 1;
          break;
	    case 's':
          if (sdone) {
            fprintf (stderr,"call_edit: `%%s' appears twice in editor command\n");
            exit(EXIT_FAILURE);
          }
          while (*fname)
		    *temp++ = *fname++;
          *temp++ = '.';
		  *temp++ = 'm';
		  *temp++ = 'p';
          sdone = 1;
          break;
	    case '\0':
          *temp++ = '%';
          /* Back up to the null to force termination.  */
	      edit_value--;
	      break;
	    default:
	      *temp++ = '%';
	      *temp++ = c;
	      break;
	    }
	 } else {
     	*temp++ = c;
     }
   }
  *temp = 0;
  if (system (command) != 0)
    fprintf (stderr, "! Trouble executing `%s'.\n", command);
  exit(EXIT_FAILURE);
}

@ 
@<Register the callback routines@>=
options->run_editor = mpost_run_editor;

@
@c 
string normalize_quotes (const char *name, const char *mesg) {
    int quoted = false;
    int must_quote = (strchr(name, ' ') != NULL);
    /* Leave room for quotes and NUL. */
    string ret = (string)xmalloc(strlen(name)+3);
    string p;
    const_string q;
    p = ret;
    if (must_quote)
        *p++ = '"';
    for (q = name; *q; q++) {
        if (*q == '"')
            quoted = !quoted;
        else
            *p++ = *q;
    }
    if (must_quote)
        *p++ = '"';
    *p = '\0';
    if (quoted) {
        fprintf(stderr, "! Unbalanced quotes in %s %s\n", mesg, name);
        exit(EXIT_FAILURE);
    }
    return ret;
}

@ @c 
static char *makempx_find_file (MPX mpx, const char *nam, const char *mode, int ftype) {
  (void) mpx;
  int format, req;
  if (mode[0] != 'r') { 
     return strdup(nam);
  }
  req = 1;
  switch(ftype) {
  case mpx_tfm_format:       format = kpse_tfm_format; break;
  case mpx_vf_format:        format = kpse_vf_format; req = 0; break;
  case mpx_trfontmap_format: format = kpse_mpsupport_format; break;
  case mpx_trcharadj_format: format = kpse_mpsupport_format; break;
  case mpx_desc_format:      format = kpse_troff_font_format; break;
  case mpx_fontdesc_format:  format =  kpse_troff_font_format; break;
  case mpx_specchar_format:  format =  kpse_mpsupport_format; break;
  default:                   return NULL;  break;
  }
  return  kpse_find_file (nam, format, req);
}

@ Invoke makempx (or troffmpx) to make sure there is an up-to-date
   .mpx file for a given .mp file.  (Original from John Hobby 3/14/90) 

@d default_args " --parse-first-line --interaction=nonstopmode"
@d TEX     "tex"
@d TROFF   "soelim | eqn -Tps -d$$ | troff -Tps"

@c
#ifndef MPXCOMMAND
#define MPXCOMMAND "makempx"
#endif
int mpost_run_make_mpx (MP mp, char *mpname, char *mpxname) {
  int ret;
  string cnf_cmd = kpse_var_value ("MPXCOMMAND");
  
  if (cnf_cmd && (strcmp (cnf_cmd, "0")==0)) {
    /* If they turned off this feature, just return success.  */
    ret = 0;

  } else {
    /* We will invoke something. Compile-time default if nothing else.  */
    string cmd;
    string qmpname = normalize_quotes(mpname, "mpname");
    string qmpxname = normalize_quotes(mpxname, "mpxname");
    if (cnf_cmd) {
      if (mp_troff_mode(mp))
        cmd = concatn (cnf_cmd, " -troff ",
                     qmpname, " ", qmpxname, NULL);
      else if (mpost_tex_program && *mpost_tex_program)
        cmd = concatn (cnf_cmd, " -tex=", mpost_tex_program, " ",
                     qmpname, " ", qmpxname, NULL);
      else
        cmd = concatn (cnf_cmd, " -tex ", qmpname, " ", qmpxname, NULL);
  
      /* Run it.  */
      ret = system (cmd);
      free (cmd);
    } else {
      makempx_options * mpxopt;
      const char *mpversion = mp_metapost_version () ;
      mpxopt = xmalloc(sizeof(makempx_options));
      char *s = NULL;
      char *maincmd = NULL;
      int mpxmode = mp_troff_mode(mp);
      if (mpost_tex_program && *mpost_tex_program) {
        maincmd = xstrdup(mpost_tex_program);
      } else {
        if (mpxmode == mpx_tex_mode) {
          s = kpse_var_value("TEX");
          if (!s) s = kpse_var_value("MPXMAINCMD");
          if (!s) s = xstrdup (TEX);
          maincmd = (char *)xmalloc (strlen(s)+strlen(default_args)+1);
          strcpy(maincmd,s);
          strcat(maincmd,default_args);
          free(s);
        } else {
          s = kpse_var_value("TROFF");
          if (!s) s = kpse_var_value("MPXMAINCMD");
          if (!s) s = xstrdup (TROFF);
          maincmd = s;
        }
      }
      mpxopt->mode = mpxmode;
      mpxopt->cmd  = maincmd;
      mpxopt->mptexpre = kpse_var_value("MPTEXPRE");
      mpxopt->mpname = qmpname;
      mpxopt->mpxname = qmpxname;
      mpxopt->debug = debug;
      mpxopt->find_file = makempx_find_file;
      {
        char *banner = "% Written by metapost version ";
        mpxopt->banner = xmalloc(strlen(mpversion)+strlen(banner)+1);
        strcpy (mpxopt->banner, banner);
        strcat (mpxopt->banner, mpversion);
      }
      ret = mp_makempx(mpxopt);
      free(mpxopt->cmd);
      free(mpxopt->mptexpre);
      free(mpxopt);
    }
    free (qmpname);
    free (qmpxname);
  }

  free (cnf_cmd);
  return ret == 0;
}

@ 
@<Register the callback routines@>=
if (!nokpse)
  options->run_make_mpx = mpost_run_make_mpx;


@ @c 
static int get_random_seed (void) {
  int ret ;
#if defined (HAVE_GETTIMEOFDAY)
  struct timeval tv;
  gettimeofday(&tv, NULL);
  ret = (tv.tv_usec + 1000000 * tv.tv_usec);
#elif defined (HAVE_FTIME)
  struct timeb tb;
  ftime(&tb);
  ret = (tb.millitm + 1000 * tb.time);
#else
  time_t clock = time ((time_t*)NULL);
  struct tm *tmptr = localtime(&clock);
  ret = (tmptr->tm_sec + 60*(tmptr->tm_min + 60*tmptr->tm_hour));
#endif
  return ret;
}

@ @<Register the callback routines@>=
options->random_seed = get_random_seed();

@ @c 
char *mpost_find_file(MP mp, const char *fname, const char *fmode, int ftype)  {
  int l ;
  char *s = NULL;
  (void)mp;
  if (fmode[0]=='r') {
	if (ftype>=mp_filetype_text) {
      s = kpse_find_file (fname, kpse_mp_format, 0); 
    } else {
    switch(ftype) {
    case mp_filetype_program: 
      l = strlen(fname);
   	  if (l>3 && strcmp(fname+l-3,".mf")==0) {
   	    s = kpse_find_file (fname, kpse_mf_format, 0); 
      } else {
   	    s = kpse_find_file (fname, kpse_mp_format, 0); 
      }
      break;
    case mp_filetype_memfile: 
      s = kpse_find_file (fname, kpse_mem_format, 0); 
      break;
    case mp_filetype_metrics: 
      s = kpse_find_file (fname, kpse_tfm_format, 0); 
      break;
    case mp_filetype_fontmap: 
      s = kpse_find_file (fname, kpse_fontmap_format, 0); 
      break;
    case mp_filetype_font: 
      s = kpse_find_file (fname, kpse_type1_format, 0); 
      break;
    case mp_filetype_encoding: 
      s = kpse_find_file (fname, kpse_enc_format, 0); 
      break;
    }
    }
  } else {
    s = xstrdup(fname); /* when writing */
  }
  return s;
}

@  @<Register the callback routines@>=
if (!nokpse)
  options->find_file = mpost_find_file;

@ @c 
void *mpost_open_file(MP mp, const char *fname, const char *fmode, int ftype)  {
  char realmode[3];
  char *s;
  if (ftype==mp_filetype_terminal) {
    return (fmode[0] == 'r' ? stdin : stdout);
  } else if (ftype==mp_filetype_error) {
    return stderr;
  } else { 
    s = mpost_find_file (mp, fname, fmode, ftype);
    if (s!=NULL) {
      void *ret = NULL;
      realmode[0] = *fmode;
	  realmode[1] = 'b';
	  realmode[2] = 0;
      ret = fopen(s,realmode);
      free(s);
      return ret;
    }
  }
  return NULL;
}

@  @<Register the callback routines@>=
if (!nokpse)
  options->open_file = mpost_open_file;


@ At the moment, the command line is very simple.

@d option_is(A) ((strncmp(argv[a],"--" A, strlen(A)+2)==0) || 
       (strncmp(argv[a],"-" A, strlen(A)+1)==0))
@d option_arg(B) (optarg && strncmp(optarg,B, strlen(B))==0)


@<Read and set command line options@>=
{
  char *optarg;
  boolean ini_version_test = false;
  while (++a<argc) {
    optarg = strstr(argv[a],"=") ;
    if (optarg!=NULL) {
      optarg++;
      if (!*optarg)  optarg=NULL;
    }
    if (option_is("ini")) {
      ini_version_test = true;
    } else if (option_is("debug")) {
      debug = 1;
    } else if (option_is ("kpathsea-debug")) {
      kpathsea_debug |= atoi (optarg);
    } else if (option_is("mem")) {
      options->mem_name = xstrdup(optarg);
      if (!user_progname) 
	    user_progname = optarg;
    } else if (option_is("jobname")) {
      options->job_name = xstrdup(optarg);
    } else if (option_is ("progname")) {
      user_progname = optarg;
    } else if (option_is("troff")) {
      options->troff_mode = true;
    } else if (option_is ("tex")) {
      mpost_tex_program = optarg;
    } else if (option_is("interaction")) {
      if (option_arg("batchmode")) {
        options->interaction = mp_batch_mode;
      } else if (option_arg("nonstopmode")) {
        options->interaction = mp_nonstop_mode;
      } else if (option_arg("scrollmode")) {
        options->interaction = mp_scroll_mode;
      } else if (option_arg("errorstopmode")) {
        options->interaction = mp_error_stop_mode;
      } else {
        fprintf(stdout,"unknown option argument %s\n", argv[a]);
      }
    } else if (option_is("no-kpathsea")) {
      nokpse=1;
    } else if (option_is("help")) {
      @<Show help and exit@>;
    } else if (option_is("version")) {
      @<Show version and exit@>;
    } else if (option_is("")) {
      continue; /* ignore unknown options */
    } else {
      break;
    }
  }
  options->ini_version = ini_version_test;
}

@ 
@<Show help...@>=
{
fprintf(stdout,
"\n"
"Usage: mpost [OPTION] [MPNAME[.mp]] [COMMANDS]\n"
"\n"
"  Run MetaPost on MPNAME, usually creating MPNAME.NNN (and perhaps\n"
"  MPNAME.tfm), where NNN are the character numbers generated.\n"
"  Any remaining COMMANDS are processed as MetaPost input,\n"
"  after MPNAME is read.\n\n");
fprintf(stdout,
"  If no arguments or options are specified, prompt for input.\n"
"\n"
"  -ini                    be inimpost, for dumping mems\n"
"  -interaction=STRING     set interaction mode (STRING=batchmode/nonstopmode/\n"
"                          scrollmode/errorstopmode)\n"
"  -jobname=STRING         set the job name to STRING\n"
"  -progname=STRING        set program (and mem) name to STRING\n");
fprintf(stdout,
"  -tex=TEXPROGRAM         use TEXPROGRAM for text labels\n"
"  -kpathsea-debug=NUMBER  set path searching debugging flags according to\n"
"                          the bits of NUMBER\n"
"  -mem=MEMNAME            use MEMNAME instead of program name or a %%& line\n"
"  -troff                  set the prologues variable, use `makempx -troff'\n"
"  -help                   display this help and exit\n"
"  -version                output version information and exit\n"
"\n"
"Email bug reports to mp-implementors@@tug.org.\n"
"\n");
  exit(EXIT_SUCCESS);
}

@ 
@<Show version...@>=
{
fprintf(stdout, 
"\n"
"MetaPost %s\n"
"Copyright 2008 AT&T Bell Laboratories.\n"
"There is NO warranty.  Redistribution of this software is\n"
"covered by the terms of both the MetaPost copyright and\n"
"the Lesser GNU General Public License.\n"
"For more information about these matters, see the file\n"
"named COPYING and the MetaPost source.\n"
"Primary author of MetaPost: John Hobby.\n"
"Current maintainer of MetaPost: Taco Hoekwater.\n"
"\n", mp_metapost_version());
  exit(EXIT_SUCCESS);
}

@ The final part of the command line, after option processing, is
stored in the \MP\ instance, this will be taken as the first line of
input.

@d command_line_size 256

@<Copy the rest of the command line@>=
{
  options->command_line = xmalloc(command_line_size);
  strcpy(options->command_line,"");
  if (a<argc) {
    k=0;
    for(;a<argc;a++) {
      char *c = argv[a];
      while (*c) {
	    if (k<(command_line_size-1)) {
          options->command_line[k++] = *c;
        }
        c++;
      }
      options->command_line[k++] = ' ';
    }
	while (k>0) {
      if (options->command_line[(k-1)] == ' ') 
        k--; 
      else 
        break;
    }
    options->command_line[k] = 0;
  }
}

@ A simple function to get numerical |texmf.cnf| values
@c
int setup_var (int def, const char *var_name, int nokpse) {
  if (!nokpse) {
    char * expansion = kpse_var_value (var_name);
    if (expansion) {
      int conf_val = atoi (expansion);
      free (expansion);
      if (conf_val > 0) {
        return conf_val;
      }
    }
  }
  return def;
}

@ @<Set up the banner line@>=
{
  const char *mpversion = mp_metapost_version () ;
  const char * banner = "This is MetaPost, version ";
  const char * kpsebanner_start = " (";
  const char * kpsebanner_stop = ")";
  options->banner = xmalloc(strlen(banner)+
                            strlen(mpversion)+
                            strlen(kpsebanner_start)+
                            strlen(kpathsea_version_string)+
                            strlen(kpsebanner_stop)+1);
  strcpy (options->banner, banner);
  strcat (options->banner, mpversion);
  strcat (options->banner, kpsebanner_start);
  strcat (options->banner, kpathsea_version_string);
  strcat (options->banner, kpsebanner_stop);
}


@ Now this is really it: \MP\ starts and ends here.

@d xfree(A) if (A!=NULL) free(A)

@c 
int main (int argc, char **argv) { /* |start_here| */
  int k; /* index into buffer */
  int history; /* the exit status */
  MP mp; /* a metapost instance */
  struct MP_options * options; /* instance options */
  int a=0; /* argc counter */
  int nokpse = 0; /* switch to {\it not} enable kpse */
  char *user_progname = NULL; /* If the user overrides argv[0] with -progname.  */
  options = mp_options();
  options->ini_version       = false;
  options->print_found_names = true;
  @<Read and set command line options@>;
  if (!nokpse)
    kpse_set_program_name("mpost",user_progname);  
  if(putenv((char *)"engine=metapost"))
    fprintf(stdout,"warning: could not set up $engine\n");
  options->main_memory       = setup_var (50000,"main_memory",nokpse);
  options->hash_size         = setup_var (16384,"hash_size",nokpse);
  options->max_in_open       = setup_var (25,"max_in_open",nokpse);
  options->param_size        = setup_var (1500,"param_size",nokpse);
  options->error_line        = setup_var (79,"error_line",nokpse);
  options->half_error_line   = setup_var (50,"half_error_line",nokpse);
  options->max_print_line    = setup_var (100,"max_print_line",nokpse);
  @<Set up the banner line@>;
  @<Copy the rest of the command line@>;
  @<Register the callback routines@>;
  mp = mp_initialize(options);
  xfree(options->command_line);
  xfree(options->mem_name);
  xfree(options->job_name);
  xfree(options->banner);
  free(options);
  if (mp==NULL)
	exit(EXIT_FAILURE);
  history = mp_status(mp);
  if (history)
	exit(history);
  history = mp_run(mp);
  (void)mp_finish(mp);
  exit(history);
}

