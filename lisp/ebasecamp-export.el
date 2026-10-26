;;; ebasecamp-export.el --- ebasecamp 导出（清单 → 部署用 compose） -*- lexical-binding: t; -*-

;; Author: Thomas
;; Version: 0.6.0
;; Keywords: tools, convenience
;; Package-Requires: ((emacs "27.1"))

;;; Commentary:

;; 清单 → **部署用** compose 文件：把项目引用的 per-project 组渲染成一份自洽、
;; 可直接 `docker compose up -d' 的 compose 文件，落在项目仓库里。
;;
;; 与 `ebasecamp-compose' 的分工：渲染逻辑（YAML 序列化、标签注入、命名卷、
;; `${VAR}' 保真）全部由 `ebasecamp-compose-render' 提供，本模块只负责
;; 「选哪个项目、渲染哪些组、写到哪里、写完怎么校验」。因此这里不复制任何
;; YAML 生成代码 —— 导出物与缓存生成物的差异只来自下面两处输入调整。
;;
;; 导出语义（与缓存生成物的三处差异）：
;; 1. **只渲染 per-project 组**：shared 组（`ebc-shared' compose 项目）的服务由
;;    部署环境自行提供，写进导出文件会让 `docker compose up' 试图在部署机上
;;    重建基础设施。按 per-project 组的名字列表走 `GROUP-FILTER'，跨 scope 的
;;    depends-on 由渲染层按过滤器剔除。
;; 2. **不声明 `ebasecamp' external network**：导出物要能脱离 ebasecamp 部署，
;;    因此渲染的是项目的**副本**（`copy-ebasecamp-project'）且 `:shared-network'
;;    置 nil。服务的自定义网络照旧保留，由 compose 按项目自建
;;    `<compose 项目名>_<网络名>'。
;; 3. **带生成头注释**：来源项目、事实源清单路径、重新生成命令、shared 组未包含
;;    的说明。头注释全部以 `#' 开头，不影响 `docker compose config'。
;;
;; 落盘是原子的：先写同目录的 `<target>.tmp'，用 `ebasecamp-docker-check-compose'
;; （`docker compose config -q'，判据为「退出码 + stderr」双条件）校验，通过才
;; rename 到目标路径；校验失败删临时文件并 signal，目标路径不会出现半写文件。
;;
;; 覆盖策略：`FORCE' 非 nil 直接覆盖；否则非交互场景 signal；交互场景给出
;; 「换一个路径 / 覆盖 / 取消」三选一（`read-char-choice'）。
;;
;; 安全约定：本模块不插值、不打印、不落盘任何密钥值。`${VAR}' 引用由渲染层原样
;; 保留，写入的只有引用本身。

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'ebasecamp-model)
(require 'ebasecamp-config)
(require 'ebasecamp-compose)
(require 'ebasecamp-docker)

(define-error 'ebasecamp-export-error "ebasecamp 导出失败")

(defconst ebasecamp-export--default-file-name "docker-compose.ebasecamp.yaml"
  "项目未指定 `:export-file' 时，导出文件在项目根目录下的文件名。")

(defvar ebasecamp-export--interactive nil
  "非 nil 表示允许在覆盖冲突时向用户提问。
`ebasecamp-export-compose' 在被交互式调用时把它绑成 t；直接调用
`ebasecamp-export-project' 时由 `called-interactively-p' 判定。批量脚本里
保持 nil，冲突一律 signal，不阻塞在迷你缓冲区上。")

(defun ebasecamp-export--fail (format-string &rest args)
  "以 `ebasecamp-export-error' 报告导出失败。
FORMAT-STRING 与 ARGS 组成人类可读的错误描述。"
  (signal 'ebasecamp-export-error
          (list (apply #'format format-string args))))

(defun ebasecamp-export--check-project (project)
  "校验 PROJECT 为 `ebasecamp-project' 对象，否则 signal。"
  (unless (ebasecamp-project-p project)
    (ebasecamp-export--fail "PROJECT 必须是 ebasecamp-project 对象，得到 %S"
                            project)))

;;; 路径

(defun ebasecamp-export-default-file (project)
  "返回 PROJECT 的默认导出文件绝对路径。
优先取项目的 `:export-file'（相对路径按 `:root' 展开）；否则取
`<root>/docker-compose.ebasecamp.yaml'。两者都没有时 signal
`ebasecamp-export-error' —— 没有根目录就无法把「可随时重建的派生产物」定位到
项目仓库里。"
  (ebasecamp-export--check-project project)
  (let ((export-file (ebasecamp-project-export-file project))
        (root (ebasecamp-project-root project)))
    (cond
     (export-file
      (expand-file-name export-file
                        (if root
                            (file-name-as-directory (expand-file-name root))
                          default-directory)))
     (root
      (expand-file-name ebasecamp-export--default-file-name
                        (file-name-as-directory (expand-file-name root))))
     (t
      (ebasecamp-export--fail
       "项目 %s 既没有 :root 也没有 :export-file，无法推导导出路径；请设置 :root 或显式传入 :file"
       (ebasecamp-project-name project))))))

(defun ebasecamp-export--target-or-prompt (project file)
  "返回 PROJECT 的导出目标路径；无 `:root' 也无 `:export-file' 时交互式提问。
判定顺序（**精确前置判定**，不靠 `condition-case' 捕获
`ebasecamp-export-error' —— 宽捕获会把 `ebasecamp-export-default-file' 将来
新增的任何错误误判成「需要 prompt」）：

1. FILE 非 nil → 按 `default-directory' 展开后返回；
2. 项目有 `:root' 或 `:export-file' → 由 `ebasecamp-export-default-file'
   正常推导（它 signal 就让它 signal，文案不变）；
3. 两者都无且 `ebasecamp-export--prompt-p' 为真 → 用 `read-file-name' 让用户
   显式选路径，起始目录 `default-directory'，默认名
   `ebasecamp-export--default-file-name'；
4. 其余（两者都无且非交互）→ 仍调 `ebasecamp-export-default-file'，由它
   signal 原文案「既没有 :root 也没有 :export-file」。

注意 `ebasecamp-export--prompt-p' 在 `emacs -Q --batch' 下恒为 nil
（`(not noninteractive)' 恒假）：ERT 要覆盖第 3 条必须 `cl-letf' 打桩该函数，
绑 `ebasecamp-export--interactive' 或 `called-interactively-p' 都无效。"
  (cond
   (file (expand-file-name file))
   ((or (ebasecamp-project-root project)
        (ebasecamp-project-export-file project))
    (ebasecamp-export-default-file project))
   ((ebasecamp-export--prompt-p)
    (expand-file-name
     (read-file-name "导出到文件："
                     (file-name-as-directory (expand-file-name default-directory))
                     nil ebasecamp-export--default-file-name)))
   (t (ebasecamp-export-default-file project))))

(defun ebasecamp-export--relative-path-notice (project target)
  "返回「导出目录不是项目 root」的提示串；无需提示时返回 nil。
判据（顺序有意义）：PROJECT 的 `:root' 为 nil、或它指向**不存在的目录**时一律
返回 nil —— 清单里的 root 可能指向尚未创建的目录，此时 `file-truename' 只做
尾部分规范化，与已 `make-directory' 的导出目录比较会恒判「不等价」而每次都
误报。root 存在则把 `TARGET' 所在目录与 root 都用 `file-truename' +
`file-name-as-directory' 归一等价比较，不等价时返回提示串。

只负责生成文案：是否提示、何时提示由调用方决定（`ebasecamp-export--write'
在 rename 成功后 `message' 一次），返回值与导出成败都不受影响。"
  (let ((root (ebasecamp-project-root project)))
    (when (and root (file-exists-p root))
      (let* ((root-dir (file-name-as-directory
                        (file-truename (expand-file-name root))))
             (target-dir (file-name-as-directory
                          (file-truename
                           (or (file-name-directory (expand-file-name target))
                               default-directory)))))
        (unless (equal root-dir target-dir)
          (format (concat "导出目录 %s 不是项目 root %s：生成物里的相对路径"
                          "（env_file / bind 挂载）在部署时按导出目录解析，"
                          "请确认相关文件随生成物一同部署。")
                  (directory-file-name target-dir)
                  (directory-file-name root-dir)))))))

;;; 渲染内容

(defun ebasecamp-export--per-project-refs (project)
  "返回 PROJECT 中 per-project 组的引用 plist 列表（保持项目定义顺序）。
scope 的判定复用渲染层的口径：引用上的 `:scope' 覆盖组自身声明，缺省
per-project。"
  (cl-remove-if (lambda (ref)
                  (eq 'shared (ebasecamp-compose--ref-scope ref)))
                (ebasecamp-project-groups project)))

(defun ebasecamp-export--shared-group-names (project)
  "返回 PROJECT 引用的 shared 组名列表（symbol），保持项目定义顺序。"
  (let ((names nil))
    (dolist (ref (ebasecamp-project-groups project))
      (when (eq 'shared (ebasecamp-compose--ref-scope ref))
        (let ((name (ebasecamp-compose--ref-group-name ref)))
          (unless (memq name names)
            (setq names (append names (list name)))))))
    names))

(defun ebasecamp-export--deployment-project (project)
  "返回 PROJECT 的部署视图副本：`shared-network' 置 nil，其余字段不变。
用副本而不是就地修改，是因为项目对象属于清单注册表，导出不应有副作用；
副本的 groups / services 与原件共享（渲染层对这些字段一律只读）。"
  (let ((copy (copy-ebasecamp-project project)))
    (setf (ebasecamp-project-shared-network copy) nil)
    copy))

(defun ebasecamp-export--header (project)
  "返回 PROJECT 导出文件的头注释块（以单个换行结尾）。
含来源项目、事实源清单路径、重新生成命令与 shared 组未包含说明。"
  (let* ((name (ebasecamp-project-name project))
         (shared (ebasecamp-export--shared-group-names project))
         (groups (mapcar (lambda (ref)
                           (symbol-name (ebasecamp-compose--ref-group-name ref)))
                         (ebasecamp-export--per-project-refs project))))
    (concat
     "# 由 ebasecamp 生成，请勿手工编辑。\n"
     "#\n"
     "# 项目：" (format "%s" name) "\n"
     "# 事实源：" (ebasecamp-config-project-file name) "\n"
     "# 重新生成：M-x ebasecamp-export-compose 选择项目 " (format "%s" name)
     "，或\n"
     "#   (ebasecamp-export-project (ebasecamp-model-project '" (format "%s" name)
     ") :force t)\n"
     "#\n"
     "# 说明：只含项目 " (format "%s" name) " 的 per-project 组服务（组："
     (mapconcat #'identity groups "、") "）。\n"
     (if shared
         (concat "#       shared 组（"
                 (mapconcat #'symbol-name shared "、")
                 "）的服务由部署环境自行提供，不在本文件中。\n")
       "#       本项目未引用 shared 组。\n")
     "#       因此本文件不声明 ebasecamp 共享网络；服务原有的自定义网络由\n"
     "#       compose 按项目自建（" (format "%s" name) "_<网络名>）。\n")))

(defun ebasecamp-export--content (project)
  "返回 PROJECT 导出文件的完整文本（头注释 + compose 正文）。
只渲染 per-project 组，且用关闭 `shared-network' 的项目副本渲染，因此导出物
不声明 `ebasecamp' external network。项目没有 per-project 组时 signal ——
空文件部署起来没有意义，静默产出会被误用。"
  (let* ((refs (ebasecamp-export--per-project-refs project))
         (filter (mapcar #'ebasecamp-compose--ref-group-name refs)))
    (unless refs
      (ebasecamp-export--fail
       "项目 %s 没有 per-project 组，无可导出的服务"
       (ebasecamp-project-name project)))
    (concat (ebasecamp-export--header project)
            "\n"
            (ebasecamp-compose-render
             (ebasecamp-export--deployment-project project) filter))))

;;; 冲突处理

(defun ebasecamp-export--prompt-p ()
  "判断当前是否允许就覆盖冲突向用户提问。
批处理（`noninteractive' 非 nil）下永不提问；否则要求本次调用处于交互上下文
（`ebasecamp-export-compose' 被交互式调用时把 `ebasecamp-export--interactive'
绑成 t）。"
  (and (not noninteractive)
       (or ebasecamp-export--interactive
           (called-interactively-p 'any))))

(defun ebasecamp-export--read-choice (target)
  "就「TARGET 已存在」向用户提问，返回 ?r（换路径）、?o（覆盖）或 ?c（取消）。"
  (read-char-choice
   (format "%s 已存在：[r] 换一个路径  [o] 覆盖  [c] 取消 " target)
   '(?r ?o ?c)))

;;; 校验与落盘

(defun ebasecamp-export--delete-file (file)
  "删除 FILE（不存在时什么也不做）。"
  (when (file-exists-p file)
    (delete-file file)))

(defun ebasecamp-export--write (project target)
  "把 PROJECT 的导出内容原子写入 TARGET 并返回 TARGET。
先写同目录的 `<TARGET>.tmp'，用 `ebasecamp-docker-check-compose' 校验；通过则
rename 到 TARGET（原子替换），失败则删除临时文件并 signal（TARGET 不动）。

rename 成功后若导出目录不是项目 root（见
`ebasecamp-export--relative-path-notice'），`message' 一条提示：返回值与成败
都不受影响，提示也不进入文件内容。校验基准始终是导出目录本身（不传 root）——
校验通过即部署通过，两者的相对路径基准必须一致。"
  (let* ((tmp (concat target ".tmp"))
         (text (ebasecamp-export--content project))
         (coding-system-for-write 'utf-8-unix))
    (make-directory (file-name-directory target) t)
    (with-temp-file tmp
      (insert text))
    (let ((result (ebasecamp-docker-check-compose tmp)))
      (if (plist-get result :ok)
          (progn
            (rename-file tmp target t)
            (when-let* ((notice (ebasecamp-export--relative-path-notice
                                project target)))
              (message "%s" notice))
            target)
        (ebasecamp-export--delete-file tmp)
        (ebasecamp-export--fail
         "%s 未通过 compose 校验（退出码 %s）：%s"
         target
         (plist-get result :exit)
         (let ((stderr (string-trim (or (plist-get result :stderr) ""))))
           (if (string-empty-p stderr) "无输出" stderr)))))))

;;; 公共接口

(cl-defun ebasecamp-export-project (project &key file force)
  "把 PROJECT 导出为部署用 compose 文件，返回目标绝对路径。
取消导出时返回 nil。

FILE 为目标路径，省略时用 `ebasecamp-export-default-file'；项目**既无 `:root'
也无 `:export-file'** 时，交互式改用 `read-file-name' 让用户显式选路径（非交互
仍 signal，用于不带 `--project-directory' 的批处理与无根目录项目）。目标已存在时：
FORCE 非 nil 直接覆盖；`noninteractive' 或非交互调用 signal
`ebasecamp-export-error'；交互式则询问「换一个路径 / 覆盖 / 取消」，选「换
一个路径」时递归让用户用 `read-file-name' 重新指定。

导出内容为头注释 + 只含 per-project 组的 compose 正文（不声明 `ebasecamp'
external network），先写临时文件并经 `docker compose config -q' 校验，通过才
原子替换目标 —— 校验失败时目标路径不会出现半写文件。

目标是覆盖缓存生成物、供部署的产物：部署时 compose 以**文件所在目录**为基准
解析相对路径，因此导出目录不是项目 root 时只 `message' 一条提示（见
`ebasecamp-export--relative-path-notice'），不失败、不改返回值。"
  (ebasecamp-export--check-project project)
  (let ((target (ebasecamp-export--target-or-prompt project file)))
    (cond
     ((not (file-exists-p target))
      (ebasecamp-export--write project target))
     (force
      (ebasecamp-export--write project target))
     ((not (ebasecamp-export--prompt-p))
      (ebasecamp-export--fail "%s 已存在；覆盖需显式指定 :force" target))
     (t
      (pcase (ebasecamp-export--read-choice target)
        (?r (ebasecamp-export-project
             project
             :file (read-file-name
                    "导出到文件：" (file-name-directory target) nil
                    (file-name-nondirectory target))
             :force force))
        (?o (ebasecamp-export--write project target))
        (_ nil))))))

(defun ebasecamp-export--read-project ()
  "从清单里读一个项目名，返回对应的项目对象。
清单为空时 `user-error'。"
  (let ((projects (ebasecamp-model-projects)))
    (unless projects
      (user-error "清单中没有项目；请先定义项目"))
    (let ((name (completing-read
                 "导出项目：" (mapcar #'ebasecamp-project-name projects)
                 nil t)))
      (or (ebasecamp-model-project (intern name))
          (ebasecamp-export--fail "项目 %s 不在清单中" name)))))

;;;###autoload
(cl-defun ebasecamp-export-compose (&optional project file)
  "交互式把 PROJECT 导出为部署用 compose 文件，返回路径或 nil。
PROJECT 省略时用 `completing-read' 从清单里选；FILE 省略时用项目的默认导出
路径。导出详情与冲突处理见 `ebasecamp-export-project'。"
  (interactive)
  (let* ((ebasecamp-export--interactive (called-interactively-p 'any))
         (project (or project (ebasecamp-export--read-project)))
         (path (ebasecamp-export-project project :file file)))
    (when path
      (message "已导出到 %s" path))
    path))

(provide 'ebasecamp-export)
;;; ebasecamp-export.el ends here
